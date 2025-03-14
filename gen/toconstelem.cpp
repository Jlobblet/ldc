//===-- toconstelem.cpp ---------------------------------------------------===//
//
//                         LDC – the LLVM D compiler
//
// This file is distributed under the BSD-style LDC license. See the LICENSE
// file for details.
//
//===----------------------------------------------------------------------===//

#include "dmd/ctfe.h"
#include "dmd/errors.h"
#include "dmd/template.h"
#include "gen/arrays.h"
#include "gen/binops.h"
#include "gen/classes.h"
#include "gen/complex.h"
#include "gen/irstate.h"
#include "gen/llvm.h"
#include "gen/llvmhelpers.h"
#include "gen/logger.h"
#include "gen/structs.h"
#include "gen/tollvm.h"
#include "gen/typinf.h"
#include "ir/irfunction.h"
#include "ir/irtypeclass.h"
#include "ir/irtypestruct.h"

/// Emits an LLVM constant corresponding to the expression (or an error if
/// impossible).
class ToConstElemVisitor : public Visitor {
  IRState *p;
  LLConstant *result;

public:
  explicit ToConstElemVisitor(IRState *p_) : p(p_) {}

  // Import all functions from class Visitor
  using Visitor::visit;

  //////////////////////////////////////////////////////////////////////////////

  LLConstant *process(Expression *e) {
    result = nullptr;
    e->accept(this);
    return result;
  }

  //////////////////////////////////////////////////////////////////////////////

  void fatalError() {
    result = nullptr;
    if (!global.gag) {
      fatal();
    }
  }

  //////////////////////////////////////////////////////////////////////////////

  void visit(VarExp *e) override {
    IF_LOG Logger::print("VarExp::toConstElem: %s @ %s\n", e->toChars(),
                         e->type->toChars());
    LOG_SCOPE;

    if (SymbolDeclaration *sdecl = e->var->isSymbolDeclaration()) {
      // This is the static initialiser (init symbol) for aggregates.
      // Exclude void[]-typed `__traits(initSymbol)` (LDC extension).
      if (sdecl->type->toBasetype()->ty == TY::Tstruct) {
        const auto sd = sdecl->dsym->isStructDeclaration();
        assert(sd);
        IF_LOG Logger::print("Sym: sd=%s\n", sd->toChars());
        DtoResolveStruct(sd);
        result = getIrAggr(sd)->getDefaultInit();
        return;
      }
    }

    if (TypeInfoDeclaration *ti = e->var->isTypeInfoDeclaration()) {
      result = DtoTypeInfoOf(e->loc, ti->tinfo, /*base=*/false);
      result = DtoBitCast(result, DtoType(e->type));
      return;
    }

    VarDeclaration *vd = e->var->isVarDeclaration();
    if (vd && vd->isConst() && vd->_init) {
      if (vd->inuse) {
        e->error("recursive reference `%s`", e->toChars());
        result = nullptr;
      } else {
        vd->inuse++;
        // return the initializer
        result = DtoConstInitializer(e->loc, e->type, vd->_init);
        vd->inuse--;
      }
    }
    // fail
    else {
      e->error("non-constant expression `%s`", e->toChars());
      result = nullptr;
    }
  }

  //////////////////////////////////////////////////////////////////////////////

  void visit(IntegerExp *e) override {
    IF_LOG Logger::print("IntegerExp::toConstElem: %s @ %s\n", e->toChars(),
                         e->type->toChars());
    LOG_SCOPE;
    LLType *t = DtoType(e->type);
    if (isaPointer(t)) {
      Logger::println("pointer");
      LLConstant *i = LLConstantInt::get(
          DtoSize_t(), static_cast<uint64_t>(e->getInteger()), false);
      result = llvm::ConstantExpr::getIntToPtr(i, t);
    } else {
      assert(llvm::isa<LLIntegerType>(t));
      result = LLConstantInt::get(t, static_cast<uint64_t>(e->getInteger()),
                                  !e->type->isunsigned());
      assert(result);
      IF_LOG Logger::cout() << "value = " << *result << '\n';
    }
  }

  //////////////////////////////////////////////////////////////////////////////

  void visit(RealExp *e) override {
    IF_LOG Logger::print("RealExp::toConstElem: %s @ %s | %La\n", e->toChars(),
                         e->type->toChars(), e->value);
    LOG_SCOPE;
    Type *t = e->type->toBasetype();
    result = DtoConstFP(t, e->value);
  }

  //////////////////////////////////////////////////////////////////////////////

  void visit(NullExp *e) override {
    IF_LOG Logger::print("NullExp::toConstElem(type=%s): %s\n",
                         e->type->toChars(), e->toChars());
    LOG_SCOPE;
    LLType *t = DtoType(e->type);
    if (e->type->ty == TY::Tarray) {
      assert(isaStruct(t));
      result = llvm::ConstantAggregateZero::get(t);
    } else {
      result = LLConstant::getNullValue(t);
    }
  }

  //////////////////////////////////////////////////////////////////////////////

  void visit(ComplexExp *e) override {
    IF_LOG Logger::print("ComplexExp::toConstElem(): %s @ %s\n", e->toChars(),
                         e->type->toChars());
    LOG_SCOPE;
    result = DtoConstComplex(e->type, e->value.re, e->value.im);
  }

  //////////////////////////////////////////////////////////////////////////////

  void visit(StringExp *e) override {
    IF_LOG Logger::print("StringExp::toConstElem: %s @ %s\n", e->toChars(),
                         e->type->toChars());
    LOG_SCOPE;

    Type *const t = e->type->toBasetype();

    if (auto ts = t->isTypeSArray()) {
      bool zeroTerm = ts->dim->toInteger() == e->numberOfCodeUnits() + 1;
      result = buildStringLiteralConstant(e, zeroTerm);
      return;
    }

    llvm::GlobalVariable *gvar = p->getCachedStringLiteral(e);
    LLConstant *arrptr = DtoGEP(gvar, 0u, 0u);

    if (t->ty == TY::Tpointer) {
      result = DtoBitCast(arrptr, DtoType(t));
    } else if (t->ty == TY::Tarray) {
      LLConstant *clen =
          LLConstantInt::get(DtoSize_t(), e->numberOfCodeUnits(), false);
      result = DtoConstSlice(clen, arrptr, e->type);
    } else {
      llvm_unreachable("Unknown type for StringExp.");
    }
  }

  //////////////////////////////////////////////////////////////////////////////

  void visit(AddExp *e) override {
    IF_LOG Logger::print("AddExp::toConstElem: %s @ %s\n", e->toChars(),
                         e->type->toChars());
    LOG_SCOPE;

    // add to pointer
    Type *t1b = e->e1->type->toBasetype();
    if (t1b->ty == TY::Tpointer && e->e2->type->isintegral()) {
      llvm::Constant *ptr = toConstElem(e->e1, p);
      dinteger_t idx = undoStrideMul(e->loc, t1b, e->e2->toInteger());
      result = llvm::ConstantExpr::getGetElementPtr(getPointeeType(ptr), ptr,
                                                    DtoConstSize_t(idx));
      return;
    }

    visit(static_cast<Expression *>(e));
  }

  void visit(MinExp *e) override {
    IF_LOG Logger::print("MinExp::toConstElem: %s @ %s\n", e->toChars(),
                         e->type->toChars());
    LOG_SCOPE;

    Type *t1b = e->e1->type->toBasetype();
    if (t1b->ty == TY::Tpointer && e->e2->type->isintegral()) {
      llvm::Constant *ptr = toConstElem(e->e1, p);
      dinteger_t idx = undoStrideMul(e->loc, t1b, e->e2->toInteger());

      llvm::Constant *negIdx = llvm::ConstantExpr::getNeg(DtoConstSize_t(idx));
      result = llvm::ConstantExpr::getGetElementPtr(getPointeeType(ptr), ptr,
                                                    negIdx);
      return;
    }

    visit(static_cast<Expression *>(e));
  }

  //////////////////////////////////////////////////////////////////////////////

  void visit(CastExp *e) override {
    IF_LOG Logger::print("CastExp::toConstElem: %s @ %s\n", e->toChars(),
                         e->type->toChars());
    LOG_SCOPE;

    LLType *lltype = DtoType(e->type);
    Type *tb = e->to->toBasetype();

    // string literal to dyn array:
    // reinterpret the string data as an array, calculate the length
    if (e->e1->op == TOKstring && tb->ty == TY::Tarray) {
#if 0
            StringExp *strexp = static_cast<StringExp*>(e1);
            size_t datalen = strexp->sz * strexp->len;
            Type* eltype = tb->nextOf()->toBasetype();
            if (datalen % eltype->size() != 0) {
                error("the sizes don't line up");
                return e1->toConstElem(p);
            }
            size_t arrlen = datalen / eltype->size();
#endif
      e->error("ct cast of `string` to dynamic array not fully implemented");
      result = nullptr;
    }
    // pointer to pointer
    else if (tb->ty == TY::Tpointer &&
             e->e1->type->toBasetype()->ty == TY::Tpointer) {
      result = llvm::ConstantExpr::getBitCast(toConstElem(e->e1, p), lltype);
    }
    // global variable to pointer
    else if (tb->ty == TY::Tpointer && e->e1->op == TOKvar) {
      VarDeclaration *vd =
          static_cast<VarExp *>(e->e1)->var->isVarDeclaration();
      assert(vd);
      DtoResolveVariable(vd);
      LLConstant *value =
          isIrGlobalCreated(vd) ? isaConstant(getIrGlobal(vd)->value) : nullptr;
      if (!value) {
        goto Lerr;
      }
      Type *type = vd->type->toBasetype();
      if (type->ty == TY::Tarray || type->ty == TY::Tdelegate) {
        value = DtoGEP(value, 0u, 1u);
      }
      result = DtoBitCast(value, DtoType(tb));
    } else if (tb->ty == TY::Tclass && e->e1->type->ty == TY::Tclass &&
               e->e1->op == TOKclassreference) {
      auto cd = static_cast<ClassReferenceExp *>(e->e1)->originalClass();
      llvm::Constant *instance = toConstElem(e->e1, p);
      if (InterfaceDeclaration *it =
              static_cast<TypeClass *>(tb)->sym->isInterfaceDeclaration()) {
        assert(it->isBaseOf(cd, NULL));

        IrTypeClass *typeclass = getIrType(cd->type)->isClass();

        // find interface impl
        size_t i_index = typeclass->getInterfaceIndex(it);
        assert(i_index != ~0UL);

        // offset pointer
        instance = DtoGEP(instance, 0, i_index);
      }
      result = DtoBitCast(instance, DtoType(tb));
    } else {
      goto Lerr;
    }
    return;

  Lerr:
    e->error("cannot cast `%s` to `%s` at compile time", e->e1->type->toChars(),
             e->type->toChars());
    fatalError();
  }

  //////////////////////////////////////////////////////////////////////////////

  void visit(SymOffExp *e) override {
    IF_LOG Logger::println("SymOffExp::toConstElem: %s @ %s", e->toChars(),
                           e->type->toChars());
    LOG_SCOPE;

    llvm::Constant *base = DtoConstSymbolAddress(e->loc, e->var);
    if (base == nullptr) {
      result = nullptr;
      return;
    }

    if (e->offset == 0) {
      result = base;
    } else {
      const unsigned elemSize =
          gDataLayout->getTypeStoreSize(base->getType()->getContainedType(0));

      IF_LOG Logger::println("adding offset: %llu (elem size: %u)",
                             static_cast<unsigned long long>(e->offset),
                             elemSize);

      if (e->offset % elemSize == 0) {
        // We can turn this into a "nice" GEP.
        result = llvm::ConstantExpr::getGetElementPtr(
            getPointeeType(base), base, DtoConstSize_t(e->offset / elemSize));
      } else {
        // Offset isn't a multiple of base type size, just cast to i8* and
        // apply the byte offset.
        auto voidPtrType = getVoidPtrType();
        result = llvm::ConstantExpr::getGetElementPtr(
            voidPtrType->getElementType(), DtoBitCast(base, voidPtrType),
            DtoConstSize_t(e->offset));
      }
    }

    result = DtoBitCast(result, DtoType(e->type));
  }

  //////////////////////////////////////////////////////////////////////////////

  void visit(AddrExp *e) override {
    IF_LOG Logger::println("AddrExp::toConstElem: %s @ %s", e->toChars(),
                           e->type->toChars());
    LOG_SCOPE;
    // FIXME: this should probably be generalized more so we don't
    // need to have a case for each thing we can take the address of

    // address of global variable
    if (auto vexp = e->e1->isVarExp()) {
      LLConstant *c = DtoConstSymbolAddress(e->loc, vexp->var);
      result = c ? DtoBitCast(c, DtoType(e->type)) : nullptr;
      return;
    }

    // address of indexExp
    if (auto iexp = e->e1->isIndexExp()) {
      // indexee must be global static array var
      VarExp *vexp = iexp->e1->isVarExp();
      assert(vexp);
      VarDeclaration *vd = vexp->var->isVarDeclaration();
      assert(vd);
      assert(vd->type->toBasetype()->ty == TY::Tsarray);
      DtoResolveVariable(vd);
      assert(isIrGlobalCreated(vd));

      // get index
      LLConstant *index = toConstElem(iexp->e2, p);
      assert(index->getType() == DtoSize_t());

      // gep
      LLConstant *idxs[2] = {DtoConstSize_t(0), index};
      LLConstant *val = isaConstant(getIrGlobal(vd)->value);
      val = DtoBitCast(val, DtoType(vd->type->pointerTo()));
      LLConstant *gep = llvm::ConstantExpr::getGetElementPtr(
          getPointeeType(val), val, idxs, true);

      // bitcast to requested type
      assert(e->type->toBasetype()->ty == TY::Tpointer);
      result = DtoBitCast(gep, DtoType(e->type));
      return;
    }

    if (auto se = e->e1->isStructLiteralExp()) {
      result = p->getStructLiteralConstant(se);
      if (result) {
        IF_LOG Logger::cout()
            << "Returning existing global: " << *result << '\n';
        return;
      }

      auto globalVar = new llvm::GlobalVariable(
          p->module, DtoType(se->type), false,
          llvm::GlobalValue::InternalLinkage, nullptr, ".structliteral");
      globalVar->setAlignment(LLMaybeAlign(DtoAlignment(se->type)));

      p->setStructLiteralConstant(se, globalVar);
      llvm::Constant *constValue = toConstElem(se, p);
      constValue = p->setGlobalVarInitializer(globalVar, constValue, nullptr);
      p->setStructLiteralConstant(se, constValue);

      result = constValue;
      return;
    }

    if (e->e1->op == TOKslice || e->e1->op == TOKdotvar) {
      visit(static_cast<Expression *>(e));
      return;
    }

    llvm_unreachable("unsupported AddrExp in ToConstElemVisitor");
  }

  //////////////////////////////////////////////////////////////////////////////

  void visit(FuncExp *e) override {
    IF_LOG Logger::print("FuncExp::toConstElem: %s @ %s\n", e->toChars(),
                         e->type->toChars());
    LOG_SCOPE;

    FuncLiteralDeclaration *fd = e->fd;
    assert(fd);

    if (fd->tok == TOKreserved && e->type->ty == TY::Tpointer) {
      // This is a lambda that was inferred to be a function literal instead
      // of a delegate, so set tok here in order to get correct types/mangling.
      // Horrible hack, but DMD does the same thing in FuncExp::toElem and
      // other random places.
      fd->tok = TOKfunction;
      fd->vthis = nullptr;
    }

    if (fd->tok != TOKfunction) {
      assert(fd->tok == TOKdelegate || fd->tok == TOKreserved);

      // Only if the function doesn't access its nested context, we can emit a
      // constant delegate with context pointer being null.
      // FIXME: Find a proper way to check whether the context is used.
      //        For now, just enable it for literals declared at module scope.
      if (!fd->toParent2()->isModule()) {
        e->error("non-constant nested delegate literal expression `%s`",
                 e->toChars());
        fatalError();
        return;
      }
    }

    // We need to actually codegen the function here, as literals are not
    // added to the module member list.
    Declaration_codegen(fd, p);

    result = DtoCallee(fd, false);
    assert(result);

    if (fd->tok != TOKfunction) {
      auto contextPtr = getNullPtr(getVoidPtrType());
      result = LLConstantStruct::getAnon(gIR->context(), {contextPtr, result});
    }
  }

  //////////////////////////////////////////////////////////////////////////////

  void visit(ArrayLiteralExp *e) override {
    IF_LOG Logger::print("ArrayLiteralExp::toConstElem: %s @ %s\n",
                         e->toChars(), e->type->toChars());
    LOG_SCOPE;

    // extract D types
    Type *bt = e->type->toBasetype();
    Type *elemt = bt->nextOf();

    // build llvm array type
    LLArrayType *arrtype =
        LLArrayType::get(DtoMemType(elemt), e->elements->length);

    // dynamic arrays can occur here as well ...
    bool dyn = (bt->ty != TY::Tsarray);

    llvm::Constant *initval = arrayLiteralToConst(p, e);

    // if static array, we're done
    if (!dyn) {
      result = initval;
      return;
    }

    bool canBeConst = e->type->isConst() || e->type->isImmutable();
    auto gvar = new llvm::GlobalVariable(
        gIR->module, initval->getType(), canBeConst,
        llvm::GlobalValue::InternalLinkage, initval, ".dynarrayStorage");
    gvar->setUnnamedAddr(canBeConst ? llvm::GlobalValue::UnnamedAddr::Global
                                    : llvm::GlobalValue::UnnamedAddr::None);
    llvm::Constant *store = DtoBitCast(gvar, getPtrToType(arrtype));

    if (bt->ty == TY::Tpointer) {
      // we need to return pointer to the static array.
      result = store;
      return;
    }

    // build a constant dynamic array reference with the .ptr field pointing
    // into store
    LLConstant *globalstorePtr = DtoGEP(store, 0u, 0u);
    result = DtoConstSlice(DtoConstSize_t(e->elements->length), globalstorePtr);
  }

  //////////////////////////////////////////////////////////////////////////////

  void visit(StructLiteralExp *e) override {
    // type can legitimately be null for ClassReferenceExp::value.
    IF_LOG Logger::print("StructLiteralExp::toConstElem: %s @ %s\n",
                         e->toChars(), e->type ? e->type->toChars() : "(null)");
    LOG_SCOPE;

    if (e->useStaticInit) {
      DtoResolveStruct(e->sd);
      result = getIrAggr(e->sd)->getDefaultInit();
    } else {
      // make sure the struct is resolved
      DtoResolveStruct(e->sd);

      std::map<VarDeclaration *, llvm::Constant *> varInits;
      const size_t nexprs = e->elements->length;
      for (size_t i = 0; i < nexprs; i++) {
        if (auto elem = (*e->elements)[i]) {
          LLConstant *c = toConstElem(elem, p);
          // extend i1 to i8
          if (c->getType() == LLType::getInt1Ty(p->context()))
            c = llvm::ConstantExpr::getZExt(c, LLType::getInt8Ty(p->context()));
          varInits[e->sd->fields[i]] = c;
        }
      }

      result = getIrAggr(e->sd)->createInitializerConstant(varInits);
    }
  }

  //////////////////////////////////////////////////////////////////////////////

  void visit(ClassReferenceExp *e) override {
    IF_LOG Logger::print("ClassReferenceExp::toConstElem: %s @ %s\n",
                         e->toChars(), e->type->toChars());
    LOG_SCOPE;

    ClassDeclaration *origClass = e->originalClass();
    DtoResolveClass(origClass);
    StructLiteralExp *value = e->value;

    result = p->getStructLiteralConstant(value);
    if (result) {
      IF_LOG Logger::cout() << "Using existing global: " << *result << '\n';
    } else {
      auto globalVar = new llvm::GlobalVariable(
          p->module, getIrType(origClass->type)->isClass()->getMemoryLLType(),
          false, llvm::GlobalValue::InternalLinkage, nullptr, ".classref");
      p->setStructLiteralConstant(value, globalVar);

      std::map<VarDeclaration *, llvm::Constant *> varInits;

      // Unfortunately, ClassReferenceExp::getFieldAt is badly broken – it
      // places the base class fields _after_ those of the subclass.
      {
        const size_t nexprs = value->elements->length;

        std::stack<ClassDeclaration *> classHierachy;
        ClassDeclaration *cur = origClass;
        while (cur) {
          classHierachy.push(cur);
          cur = cur->baseClass;
        }
        size_t i = 0;
        while (!classHierachy.empty()) {
          cur = classHierachy.top();
          classHierachy.pop();
          for (size_t j = 0; j < cur->fields.length; ++j) {
            if (auto elem = (*value->elements)[i]) {
              VarDeclaration *field = cur->fields[j];
              IF_LOG Logger::println("Getting initializer for: %s",
                                     field->toChars());
              LOG_SCOPE;
              varInits[field] = toConstElem(elem, p);
            }
            ++i;
          }
        }

        (void)nexprs;
        assert(i == nexprs);
      }

      llvm::Constant *constValue =
          getIrAggr(origClass)->createInitializerConstant(varInits);
      constValue = p->setGlobalVarInitializer(globalVar, constValue, nullptr);
      p->setStructLiteralConstant(value, constValue);

      result = constValue;
    }

    if (e->type->ty == TY::Tclass) {
      ClassDeclaration *targetClass = static_cast<TypeClass *>(e->type)->sym;
      if (InterfaceDeclaration *it = targetClass->isInterfaceDeclaration()) {
        assert(it->isBaseOf(origClass, NULL));

        // find interface impl
        size_t i_index =
            getIrType(origClass->type)->isClass()->getInterfaceIndex(it);
        assert(i_index != ~0UL);

        // offset pointer
        result = DtoGEP(result, 0, i_index);
      }
    }

    assert(e->type->ty == TY::Tclass || e->type->ty == TY::Tenum);
    result = DtoBitCast(result, DtoType(e->type));
  }

  //////////////////////////////////////////////////////////////////////////////

  void visit(VectorExp *e) override {
    IF_LOG Logger::print("VectorExp::toConstElem: %s @ %s\n", e->toChars(),
                         e->type->toChars());
    LOG_SCOPE;

    TypeVector *tv = static_cast<TypeVector *>(e->to->toBasetype());
    assert(tv->ty == TY::Tvector);

    const auto elemCount =
        static_cast<TypeSArray *>(tv->basetype)->dim->toInteger();

    // Array literals are assigned element-for-element; other expressions splat
    // across the whole vector.
    if (auto ale = e->e1->isArrayLiteralExp()) {
      llvm::SmallVector<llvm::Constant *, 16> elements;
      elements.reserve(elemCount);
      for (size_t i = 0; i < elemCount; ++i) {
        elements.push_back(toConstElem(indexArrayLiteral(ale, i), p));
      }

      result = llvm::ConstantVector::get(elements);
    } else {
      // The AST for
      //   static immutable ubyte16 vec1 = 123;
      // differs from
      //    static immutable ubyte[16] vec1 = 123;
      // In the vector case the AST contains an IntegerExp (of type int) and a
      // CastExp to type ubyte. In the static array case the AST only contains
      // an IntegerExp of type ubyte. Simply call optimize to get rid of the
      // cast.
      // FIXME: Check DMD source to understand why two different ASTs are
      //        constructed.
#if LDC_LLVM_VER >= 1200
      const auto elementCount = llvm::ElementCount::getFixed(elemCount);
#elif LDC_LLVM_VER >= 1100
      const auto elementCount = llvm::ElementCount(elemCount, false);
#else
      const auto elementCount = elemCount;
#endif
      result = llvm::ConstantVector::getSplat(
          elementCount, toConstElem(e->e1->optimize(WANTvalue), p));
    }
  }

  //////////////////////////////////////////////////////////////////////////////

  void visit(TypeidExp *e) override {
    IF_LOG Logger::print("TypeidExp::toConstElem: %s @ %s\n", e->toChars(),
                         e->type->toChars());

    Type *t = isType(e->obj);
    if (!t) {
      visit(static_cast<Expression *>(e));
      return;
    }

    result = DtoTypeInfoOf(e->loc, t, /*base=*/false);
    result = DtoBitCast(result, DtoType(e->type));
  }

  //////////////////////////////////////////////////////////////////////////////

  void visit(Expression *e) override {
    e->error("expression `%s` is not a constant", e->toChars());
    fatalError();
  }
};

LLConstant *toConstElem(Expression *e, IRState *p) {
  auto ce = ToConstElemVisitor(p).process(e);
  if (!ce) {
    // error case; never return null
    ce = llvm::UndefValue::get(DtoType(e->type));
  }
  return ce;
}

LLConstant *tryToConstElem(Expression *e, IRState *p) {
  const auto errors = global.startGagging();
  auto ce = ToConstElemVisitor(p).process(e);
  if (global.endGagging(errors)) {
    return nullptr;
  }
  assert(ce);
  return ce;
}
