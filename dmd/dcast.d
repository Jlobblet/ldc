/**
 * Semantic analysis for cast-expressions.
 *
 * Copyright:   Copyright (C) 1999-2021 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 http://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/dcast.d, _dcast.d)
 * Documentation:  https://dlang.org/phobos/dmd_dcast.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/dcast.d
 */

module dmd.dcast;

import core.stdc.stdio;
import core.stdc.string;
import dmd.aggregate;
import dmd.aliasthis;
import dmd.arrayop;
import dmd.arraytypes;
import dmd.astenums;
import dmd.dclass;
import dmd.declaration;
import dmd.dscope;
import dmd.dstruct;
import dmd.dsymbol;
import dmd.errors;
import dmd.escape;
import dmd.expression;
import dmd.expressionsem;
import dmd.func;
import dmd.globals;
import dmd.impcnvtab;
import dmd.id;
import dmd.importc;
import dmd.init;
import dmd.intrange;
import dmd.mtype;
import dmd.opover;
import dmd.root.ctfloat;
import dmd.root.outbuffer;
import dmd.root.rmem;
import dmd.tokens;
import dmd.typesem;
import dmd.utf;
import dmd.visitor;

enum LOG = false;

/**
 * Attempt to implicitly cast the expression into type `t`.
 *
 * This routine will change `e`. To check the matching level,
 * use `implicitConvTo`.
 *
 * Params:
 *   e = Expression that is to be casted
 *   sc = Current scope
 *   t = Expected resulting type
 *
 * Returns:
 *   The resulting casted expression (mutating `e`), or `ErrorExp`
 *    if such an implicit conversion is not possible.
 */
Expression implicitCastTo(Expression e, Scope* sc, Type t)
{
    extern (C++) final class ImplicitCastTo : Visitor
    {
        alias visit = Visitor.visit;
    public:
        Type t;
        Scope* sc;
        Expression result;

        extern (D) this(Scope* sc, Type t)
        {
            this.sc = sc;
            this.t = t;
        }

        override void visit(Expression e)
        {
            //printf("Expression.implicitCastTo(%s of type %s) => %s\n", e.toChars(), e.type.toChars(), t.toChars());

            if (const match = (sc && sc.flags & SCOPE.Cfile) ? e.cimplicitConvTo(t) : e.implicitConvTo(t))
            {
                if (match == MATCH.constant && (e.type.constConv(t) || !e.isLvalue() && e.type.equivalent(t)))
                {
                    /* Do not emit CastExp for const conversions and
                     * unique conversions on rvalue.
                     */
                    result = e.copy();
                    result.type = t;
                    return;
                }

                auto ad = isAggregate(e.type);
                if (ad && ad.aliasthis)
                {
                    auto ts = ad.type.isTypeStruct();
                    const adMatch = ts
                        ? ts.implicitConvToWithoutAliasThis(t)
                        : ad.type.isTypeClass().implicitConvToWithoutAliasThis(t);

                    if (!adMatch)
                    {
                        Type tob = t.toBasetype();
                        Type t1b = e.type.toBasetype();
                        if (ad != isAggregate(tob))
                        {
                            if (t1b.ty == Tclass && tob.ty == Tclass)
                            {
                                ClassDeclaration t1cd = t1b.isClassHandle();
                                ClassDeclaration tocd = tob.isClassHandle();
                                int offset;
                                if (tocd.isBaseOf(t1cd, &offset))
                                {
                                    result = new CastExp(e.loc, e, t);
                                    result.type = t;
                                    return;
                                }
                            }

                            /* Forward the cast to our alias this member, rewrite to:
                             *   cast(to)e1.aliasthis
                             */
                            result = resolveAliasThis(sc, e);
                            result = result.castTo(sc, t);
                            return;
                       }
                    }
                }

                result = e.castTo(sc, t);
                return;
            }

            result = e.optimize(WANTvalue);
            if (result != e)
            {
                result.accept(this);
                return;
            }

            if (t.ty != Terror && e.type.ty != Terror)
            {
                if (!t.deco)
                {
                    e.error("forward reference to type `%s`", t.toChars());
                }
                else
                {
                    //printf("type %p ty %d deco %p\n", type, type.ty, type.deco);
                    //type = type.typeSemantic(loc, sc);
                    //printf("type %s t %s\n", type.deco, t.deco);
                    auto ts = toAutoQualChars(e.type, t);
                    e.error("cannot implicitly convert expression `%s` of type `%s` to `%s`",
                        e.toChars(), ts[0], ts[1]);
                }
            }
            result = ErrorExp.get();
        }

        override void visit(StringExp e)
        {
            //printf("StringExp::implicitCastTo(%s of type %s) => %s\n", e.toChars(), e.type.toChars(), t.toChars());
            visit(cast(Expression)e);
            if (auto se = result.isStringExp())
            {
                // Retain polysemous nature if it started out that way
                se.committed = e.committed;
            }
        }

        override void visit(ErrorExp e)
        {
            result = e;
        }

        override void visit(FuncExp e)
        {
            //printf("FuncExp::implicitCastTo type = %p %s, t = %s\n", e.type, e.type ? e.type.toChars() : NULL, t.toChars());
            FuncExp fe;
            if (e.matchType(t, sc, &fe) > MATCH.nomatch)
            {
                result = fe;
                return;
            }
            visit(cast(Expression)e);
        }

        override void visit(ArrayLiteralExp e)
        {
            visit(cast(Expression)e);

            Type tb = result.type.toBasetype();
            if (auto ta = tb.isTypeDArray())
                if (global.params.useTypeInfo && Type.dtypeinfo)
                    semanticTypeInfo(sc, ta.next);
        }

        override void visit(SliceExp e)
        {
            visit(cast(Expression)e);

            if (auto se = result.isSliceExp())
                if (auto ale = se.e1.isArrayLiteralExp())
                {
                    Type tb = t.toBasetype();
                    Type tx = (tb.ty == Tsarray)
                        ? tb.nextOf().sarrayOf(ale.elements ? ale.elements.dim : 0)
                        : tb.nextOf().arrayOf();
                    se.e1 = ale.implicitCastTo(sc, tx);
                }
        }
    }

    scope ImplicitCastTo v = new ImplicitCastTo(sc, t);
    e.accept(v);
    return v.result;
}

/**
 * Checks whether or not an expression can be implicitly converted
 * to type `t`.
 *
 * Unlike `implicitCastTo`, this routine does not perform the actual cast,
 * but only checks up to what `MATCH` level the conversion would be possible.
 *
 * Params:
 *   e = Expression that is to be casted
 *   t = Expected resulting type
 *
 * Returns:
 *   The `MATCH` level between `e.type` and `t`.
 */
MATCH implicitConvTo(Expression e, Type t)
{
    extern (C++) final class ImplicitConvTo : Visitor
    {
        alias visit = Visitor.visit;
    public:
        Type t;
        MATCH result;

        extern (D) this(Type t)
        {
            this.t = t;
            result = MATCH.nomatch;
        }

        override void visit(Expression e)
        {
            version (none)
            {
                printf("Expression::implicitConvTo(this=%s, type=%s, t=%s)\n", e.toChars(), e.type.toChars(), t.toChars());
            }
            //static int nest; if (++nest == 10) assert(0);
            if (t == Type.terror)
                return;
            if (!e.type)
            {
                e.error("`%s` is not an expression", e.toChars());
                e.type = Type.terror;
            }

            Expression ex = e.optimize(WANTvalue);
            if (ex.type.equals(t))
            {
                result = MATCH.exact;
                return;
            }
            if (ex != e)
            {
                //printf("\toptimized to %s of type %s\n", e.toChars(), e.type.toChars());
                result = ex.implicitConvTo(t);
                return;
            }

            MATCH match = e.type.implicitConvTo(t);
            if (match != MATCH.nomatch)
            {
                result = match;
                return;
            }

            /* See if we can do integral narrowing conversions
             */
            if (e.type.isintegral() && t.isintegral() && e.type.isTypeBasic() && t.isTypeBasic())
            {
                IntRange src = getIntRange(e);
                IntRange target = IntRange.fromType(t);
                if (target.contains(src))
                {
                    result = MATCH.convert;
                    return;
                }
            }
        }

        /******
         * Given expression e of type t, see if we can implicitly convert e
         * to type tprime, where tprime is type t with mod bits added.
         * Returns:
         *      match level
         */
        static MATCH implicitMod(Expression e, Type t, MOD mod)
        {
            Type tprime;
            if (t.ty == Tpointer)
                tprime = t.nextOf().castMod(mod).pointerTo();
            else if (t.ty == Tarray)
                tprime = t.nextOf().castMod(mod).arrayOf();
            else if (t.ty == Tsarray)
                tprime = t.nextOf().castMod(mod).sarrayOf(t.size() / t.nextOf().size());
            else
                tprime = t.castMod(mod);

            return e.implicitConvTo(tprime);
        }

        static MATCH implicitConvToAddMin(BinExp e, Type t)
        {
            /* Is this (ptr +- offset)? If so, then ask ptr
             * if the conversion can be done.
             * This is to support doing things like implicitly converting a mutable unique
             * pointer to an immutable pointer.
             */

            Type tb = t.toBasetype();
            Type typeb = e.type.toBasetype();

            if (typeb.ty != Tpointer || tb.ty != Tpointer)
                return MATCH.nomatch;

            Type t1b = e.e1.type.toBasetype();
            Type t2b = e.e2.type.toBasetype();
            if (t1b.ty == Tpointer && t2b.isintegral() && t1b.equivalent(tb))
            {
                // ptr + offset
                // ptr - offset
                MATCH m = e.e1.implicitConvTo(t);
                return (m > MATCH.constant) ? MATCH.constant : m;
            }
            if (t2b.ty == Tpointer && t1b.isintegral() && t2b.equivalent(tb))
            {
                // offset + ptr
                MATCH m = e.e2.implicitConvTo(t);
                return (m > MATCH.constant) ? MATCH.constant : m;
            }

            return MATCH.nomatch;
        }

        override void visit(AddExp e)
        {
            version (none)
            {
                printf("AddExp::implicitConvTo(this=%s, type=%s, t=%s)\n", e.toChars(), e.type.toChars(), t.toChars());
            }
            visit(cast(Expression)e);
            if (result == MATCH.nomatch)
                result = implicitConvToAddMin(e, t);
        }

        override void visit(MinExp e)
        {
            version (none)
            {
                printf("MinExp::implicitConvTo(this=%s, type=%s, t=%s)\n", e.toChars(), e.type.toChars(), t.toChars());
            }
            visit(cast(Expression)e);
            if (result == MATCH.nomatch)
                result = implicitConvToAddMin(e, t);
        }

        override void visit(IntegerExp e)
        {
            version (none)
            {
                printf("IntegerExp::implicitConvTo(this=%s, type=%s, t=%s)\n", e.toChars(), e.type.toChars(), t.toChars());
            }
            MATCH m = e.type.implicitConvTo(t);
            if (m >= MATCH.constant)
            {
                result = m;
                return;
            }

            TY ty = e.type.toBasetype().ty;
            TY toty = t.toBasetype().ty;
            TY oldty = ty;

            if (m == MATCH.nomatch && t.ty == Tenum)
                return;

            if (auto tv = t.isTypeVector())
            {
                TypeBasic tb = tv.elementType();
                if (tb.ty == Tvoid)
                    return;
                toty = tb.ty;
            }

            switch (ty)
            {
            case Tbool:
            case Tint8:
            case Tchar:
            case Tuns8:
            case Tint16:
            case Tuns16:
            case Twchar:
                ty = Tint32;
                break;

            case Tdchar:
                ty = Tuns32;
                break;

            default:
                break;
            }

            // Only allow conversion if no change in value
            immutable dinteger_t value = e.toInteger();

            bool isLosslesslyConvertibleToFP(T)()
            {
                if (e.type.isunsigned())
                {
                    const f = cast(T) value;
                    return cast(dinteger_t) f == value;
                }

                const f = cast(T) cast(sinteger_t) value;
                return cast(sinteger_t) f == cast(sinteger_t) value;
            }

            switch (toty)
            {
            case Tbool:
                if ((value & 1) != value)
                    return;
                break;

            case Tint8:
                if (ty == Tuns64 && value & ~0x7FU)
                    return;
                else if (cast(byte)value != value)
                    return;
                break;

            case Tchar:
                if ((oldty == Twchar || oldty == Tdchar) && value > 0x7F)
                    return;
                goto case Tuns8;
            case Tuns8:
                //printf("value = %llu %llu\n", (dinteger_t)(unsigned char)value, value);
                if (cast(ubyte)value != value)
                    return;
                break;

            case Tint16:
                if (ty == Tuns64 && value & ~0x7FFFU)
                    return;
                else if (cast(short)value != value)
                    return;
                break;

            case Twchar:
                if (oldty == Tdchar && value > 0xD7FF && value < 0xE000)
                    return;
                goto case Tuns16;
            case Tuns16:
                if (cast(ushort)value != value)
                    return;
                break;

            case Tint32:
                if (ty == Tuns32)
                {
                }
                else if (ty == Tuns64 && value & ~0x7FFFFFFFU)
                    return;
                else if (cast(int)value != value)
                    return;
                break;

            case Tuns32:
                if (ty == Tint32)
                {
                }
                else if (cast(uint)value != value)
                    return;
                break;

            case Tdchar:
                if (value > 0x10FFFFU)
                    return;
                break;

            case Tfloat32:
                if (!isLosslesslyConvertibleToFP!float)
                    return;
                break;

            case Tfloat64:
                if (!isLosslesslyConvertibleToFP!double)
                    return;
                break;

            case Tfloat80:
                if (!isLosslesslyConvertibleToFP!real_t)
                    return;
                break;

            case Tpointer:
                //printf("type = %s\n", type.toBasetype()->toChars());
                //printf("t = %s\n", t.toBasetype()->toChars());
                if (ty == Tpointer && e.type.toBasetype().nextOf().ty == t.toBasetype().nextOf().ty)
                {
                    /* Allow things like:
                     *      const char* P = cast(char *)3;
                     *      char* q = P;
                     */
                    break;
                }
                goto default;

            default:
                visit(cast(Expression)e);
                return;
            }

            //printf("MATCH.convert\n");
            result = MATCH.convert;
        }

        override void visit(ErrorExp e)
        {
            // no match
        }

        override void visit(NullExp e)
        {
            version (none)
            {
                printf("NullExp::implicitConvTo(this=%s, type=%s, t=%s)\n", e.toChars(), e.type.toChars(), t.toChars());
            }
            if (e.type.equals(t))
            {
                result = MATCH.exact;
                return;
            }

            /* Allow implicit conversions from immutable to mutable|const,
             * and mutable to immutable. It works because, after all, a null
             * doesn't actually point to anything.
             */
            if (t.equivalent(e.type))
            {
                result = MATCH.constant;
                return;
            }

            visit(cast(Expression)e);
        }

        override void visit(StructLiteralExp e)
        {
            version (none)
            {
                printf("StructLiteralExp::implicitConvTo(this=%s, type=%s, t=%s)\n", e.toChars(), e.type.toChars(), t.toChars());
            }
            visit(cast(Expression)e);
            if (result != MATCH.nomatch)
                return;
            if (e.type.ty == t.ty && e.type.isTypeStruct() && e.type.isTypeStruct().sym == t.isTypeStruct().sym)
            {
                result = MATCH.constant;
                foreach (i, el; (*e.elements)[])
                {
                    if (!el)
                        continue;
                    Type te = e.sd.fields[i].type.addMod(t.mod);
                    MATCH m2 = el.implicitConvTo(te);
                    //printf("\t%s => %s, match = %d\n", el.toChars(), te.toChars(), m2);
                    if (m2 < result)
                        result = m2;
                }
            }
        }

        override void visit(StringExp e)
        {
            version (none)
            {
                printf("StringExp::implicitConvTo(this=%s, committed=%d, type=%s, t=%s)\n", e.toChars(), e.committed, e.type.toChars(), t.toChars());
            }
            if (!e.committed && t.ty == Tpointer && t.nextOf().ty == Tvoid)
                return;

            if (!(e.type.ty == Tsarray || e.type.ty == Tarray || e.type.ty == Tpointer))
                return visit(cast(Expression)e);

            TY tyn = e.type.nextOf().ty;

            if (!tyn.isSomeChar)
                return visit(cast(Expression)e);

            switch (t.ty)
            {
            case Tsarray:
                if (e.type.ty == Tsarray)
                {
                    TY tynto = t.nextOf().ty;
                    if (tynto == tyn)
                    {
                        if (e.type.isTypeSArray().dim.toInteger() == t.isTypeSArray().dim.toInteger())
                        {
                            result = MATCH.exact;
                        }
                        return;
                    }
                    if (tynto.isSomeChar)
                    {
                        if (e.committed && tynto != tyn)
                            return;
                        size_t fromlen = e.numberOfCodeUnits(tynto);
                        size_t tolen = cast(size_t)t.isTypeSArray().dim.toInteger();
                        if (tolen < fromlen)
                            return;
                        if (tolen != fromlen)
                        {
                            // implicit length extending
                            result = MATCH.convert;
                            return;
                        }
                    }
                    if (!e.committed && tynto.isSomeChar)
                    {
                        result = MATCH.exact;
                        return;
                    }
                }
                else if (e.type.ty == Tarray)
                {
                    TY tynto = t.nextOf().ty;
                    if (tynto.isSomeChar)
                    {
                        if (e.committed && tynto != tyn)
                            return;
                        size_t fromlen = e.numberOfCodeUnits(tynto);
                        size_t tolen = cast(size_t)t.isTypeSArray().dim.toInteger();
                        if (tolen < fromlen)
                            return;
                        if (tolen != fromlen)
                        {
                            // implicit length extending
                            result = MATCH.convert;
                            return;
                        }
                    }
                    if (tynto == tyn)
                    {
                        result = MATCH.exact;
                        return;
                    }
                    if (!e.committed && tynto.isSomeChar)
                    {
                        result = MATCH.exact;
                        return;
                    }
                }
                goto case; /+ fall through +/
            case Tarray:
            case Tpointer:
                Type tn = t.nextOf();
                MATCH m = MATCH.exact;
                if (e.type.nextOf().mod != tn.mod)
                {
                    // https://issues.dlang.org/show_bug.cgi?id=16183
                    if (!tn.isConst() && !tn.isImmutable())
                        return;
                    m = MATCH.constant;
                }
                if (!e.committed)
                {
                    switch (tn.ty)
                    {
                    case Tchar:
                        if (e.postfix == 'w' || e.postfix == 'd')
                            m = MATCH.convert;
                        result = m;
                        return;
                    case Twchar:
                        if (e.postfix != 'w')
                            m = MATCH.convert;
                        result = m;
                        return;
                    case Tdchar:
                        if (e.postfix != 'd')
                            m = MATCH.convert;
                        result = m;
                        return;
                    case Tenum:
                        if (tn.isTypeEnum().sym.isSpecial())
                        {
                            /* Allow string literal -> const(wchar_t)[]
                             */
                            if (TypeBasic tob = tn.toBasetype().isTypeBasic())
                            result = tn.implicitConvTo(tob);
                            return;
                        }
                        break;
                    default:
                        break;
                    }
                }
                break;

            default:
                break;
            }

            visit(cast(Expression)e);
        }

        override void visit(ArrayLiteralExp e)
        {
            version (none)
            {
                printf("ArrayLiteralExp::implicitConvTo(this=%s, type=%s, t=%s)\n", e.toChars(), e.type.toChars(), t.toChars());
            }
            Type tb = t.toBasetype();
            Type typeb = e.type.toBasetype();

            if ((tb.ty == Tarray || tb.ty == Tsarray) &&
                (typeb.ty == Tarray || typeb.ty == Tsarray))
            {
                result = MATCH.exact;
                Type typen = typeb.nextOf().toBasetype();

                if (auto tsa = tb.isTypeSArray())
                {
                    if (e.elements.dim != tsa.dim.toInteger())
                        result = MATCH.nomatch;
                }

                Type telement = tb.nextOf();
                if (!e.elements.dim)
                {
                    if (typen.ty != Tvoid)
                        result = typen.implicitConvTo(telement);
                }
                else
                {
                    if (e.basis)
                    {
                        MATCH m = e.basis.implicitConvTo(telement);
                        if (m < result)
                            result = m;
                    }
                    for (size_t i = 0; i < e.elements.dim; i++)
                    {
                        Expression el = (*e.elements)[i];
                        if (result == MATCH.nomatch)
                            break;
                        if (!el)
                            continue;
                        MATCH m = el.implicitConvTo(telement);
                        if (m < result)
                            result = m; // remember worst match
                    }
                }

                if (!result)
                    result = e.type.implicitConvTo(t);

                return;
            }
            else if (tb.ty == Tvector && (typeb.ty == Tarray || typeb.ty == Tsarray))
            {
                result = MATCH.exact;
                // Convert array literal to vector type
                TypeVector tv = tb.isTypeVector();
                TypeSArray tbase = tv.basetype.isTypeSArray();
                assert(tbase);
                const edim = e.elements.dim;
                const tbasedim = tbase.dim.toInteger();
                if (edim > tbasedim)
                {
                    result = MATCH.nomatch;
                    return;
                }

                Type telement = tv.elementType();
                if (edim < tbasedim)
                {
                    Expression el = typeb.nextOf.defaultInitLiteral(e.loc);
                    MATCH m = el.implicitConvTo(telement);
                    if (m < result)
                        result = m; // remember worst match
                }
                foreach (el; (*e.elements)[])
                {
                    MATCH m = el.implicitConvTo(telement);
                    if (m < result)
                        result = m; // remember worst match
                    if (result == MATCH.nomatch)
                        break; // no need to check for worse
                }
                return;
            }

            visit(cast(Expression)e);
        }

        override void visit(AssocArrayLiteralExp e)
        {
            auto taa = t.toBasetype().isTypeAArray();
            Type typeb = e.type.toBasetype();

            if (!(taa && typeb.ty == Taarray))
                return visit(cast(Expression)e);

            result = MATCH.exact;
            foreach (i, el; (*e.keys)[])
            {
                MATCH m = el.implicitConvTo(taa.index);
                if (m < result)
                    result = m; // remember worst match
                if (result == MATCH.nomatch)
                    break; // no need to check for worse
                el = (*e.values)[i];
                m = el.implicitConvTo(taa.nextOf());
                if (m < result)
                    result = m; // remember worst match
                if (result == MATCH.nomatch)
                    break; // no need to check for worse
            }
        }

        override void visit(CallExp e)
        {
            enum LOG = false;
            static if (LOG)
            {
                printf("CallExp::implicitConvTo(this=%s, type=%s, t=%s)\n", e.toChars(), e.type.toChars(), t.toChars());
            }

            visit(cast(Expression)e);
            if (result != MATCH.nomatch)
                return;

            /* Allow the result of strongly pure functions to
             * convert to immutable
             */
            if (e.f &&
                (global.params.useDIP1000 != FeatureState.enabled ||        // lots of legacy code breaks with the following purity check
                 e.f.isPure() >= PURE.strong ||
                 // Special case exemption for Object.dup() which we assume is implemented correctly
                 e.f.ident == Id.dup &&
                 e.f.toParent2() == ClassDeclaration.object.toParent()) &&
                 e.f.isReturnIsolated() // check isReturnIsolated last, because it is potentially expensive.
               )
            {
                result = e.type.immutableOf().implicitConvTo(t);
                if (result > MATCH.constant) // Match level is MATCH.constant at best.
                    result = MATCH.constant;
                return;
            }

            /* Conversion is 'const' conversion if:
             * 1. function is pure (weakly pure is ok)
             * 2. implicit conversion only fails because of mod bits
             * 3. each function parameter can be implicitly converted to the mod bits
             */
            auto tf = (e.f ? e.f.type : e.e1.type).toBasetype().isTypeFunction();
            if (!tf)
                return;

            if (tf.purity == PURE.impure)
                return;
            if (e.f && e.f.isNested())
                return;

            /* See if fail only because of mod bits.
             *
             * https://issues.dlang.org/show_bug.cgi?id=14155
             * All pure functions can access global immutable data.
             * So the returned pointer may refer an immutable global data,
             * and then the returned pointer that points non-mutable object
             * cannot be unique pointer.
             *
             * Example:
             *  immutable g;
             *  static this() { g = 1; }
             *  const(int*) foo() pure { return &g; }
             *  void test() {
             *    immutable(int*) ip = foo(); // OK
             *    int* mp = foo();            // should be disallowed
             *  }
             */
            if (e.type.immutableOf().implicitConvTo(t) < MATCH.constant && e.type.addMod(MODFlags.shared_).implicitConvTo(t) < MATCH.constant && e.type.implicitConvTo(t.addMod(MODFlags.shared_)) < MATCH.constant)
            {
                return;
            }
            // Allow a conversion to immutable type, or
            // conversions of mutable types between thread-local and shared.

            /* Get mod bits of what we're converting to
             */
            Type tb = t.toBasetype();
            MOD mod = tb.mod;
            if (tf.isref)
            {
            }
            else
            {
                if (Type ti = getIndirection(t))
                    mod = ti.mod;
            }
            static if (LOG)
            {
                printf("mod = x%x\n", mod);
            }
            if (mod & MODFlags.wild)
                return; // not sure what to do with this

            /* Apply mod bits to each function parameter,
             * and see if we can convert the function argument to the modded type
             */

            size_t nparams = tf.parameterList.length;
            size_t j = tf.isDstyleVariadic(); // if TypeInfoArray was prepended
            if (auto dve = e.e1.isDotVarExp())
            {
                /* Treat 'this' as just another function argument
                 */
                Type targ = dve.e1.type;
                if (targ.constConv(targ.castMod(mod)) == MATCH.nomatch)
                    return;
            }
            foreach (const i; j .. e.arguments.dim)
            {
                Expression earg = (*e.arguments)[i];
                Type targ = earg.type.toBasetype();
                static if (LOG)
                {
                    printf("[%d] earg: %s, targ: %s\n", cast(int)i, earg.toChars(), targ.toChars());
                }
                if (i - j < nparams)
                {
                    Parameter fparam = tf.parameterList[i - j];
                    if (fparam.storageClass & STC.lazy_)
                        return; // not sure what to do with this
                    Type tparam = fparam.type;
                    if (!tparam)
                        continue;
                    if (fparam.isReference())
                    {
                        if (targ.constConv(tparam.castMod(mod)) == MATCH.nomatch)
                            return;
                        continue;
                    }
                }
                static if (LOG)
                {
                    printf("[%d] earg: %s, targm: %s\n", cast(int)i, earg.toChars(), targ.addMod(mod).toChars());
                }
                if (implicitMod(earg, targ, mod) == MATCH.nomatch)
                    return;
            }

            /* Success
             */
            result = MATCH.constant;
        }

        override void visit(AddrExp e)
        {
            version (none)
            {
                printf("AddrExp::implicitConvTo(this=%s, type=%s, t=%s)\n", e.toChars(), e.type.toChars(), t.toChars());
            }
            result = e.type.implicitConvTo(t);
            //printf("\tresult = %d\n", result);

            if (result != MATCH.nomatch)
                return;

            Type tb = t.toBasetype();
            Type typeb = e.type.toBasetype();

            // Look for pointers to functions where the functions are overloaded.
            if (e.e1.op == TOK.overloadSet &&
                (tb.ty == Tpointer || tb.ty == Tdelegate) && tb.nextOf().ty == Tfunction)
            {
                OverExp eo = e.e1.isOverExp();
                FuncDeclaration f = null;
                foreach (s; eo.vars.a[])
                {
                    FuncDeclaration f2 = s.isFuncDeclaration();
                    assert(f2);
                    if (f2.overloadExactMatch(tb.nextOf()))
                    {
                        if (f)
                        {
                            /* Error if match in more than one overload set,
                             * even if one is a 'better' match than the other.
                             */
                            ScopeDsymbol.multiplyDefined(e.loc, f, f2);
                        }
                        else
                            f = f2;
                        result = MATCH.exact;
                    }
                }
            }

            if (e.e1.op == TOK.variable &&
                typeb.ty == Tpointer && typeb.nextOf().ty == Tfunction &&
                tb.ty == Tpointer && tb.nextOf().ty == Tfunction)
            {
                /* I don't think this can ever happen -
                 * it should have been
                 * converted to a SymOffExp.
                 */
                assert(0);
            }

            //printf("\tresult = %d\n", result);
        }

        override void visit(SymOffExp e)
        {
            version (none)
            {
                printf("SymOffExp::implicitConvTo(this=%s, type=%s, t=%s)\n", e.toChars(), e.type.toChars(), t.toChars());
            }
            result = e.type.implicitConvTo(t);
            //printf("\tresult = %d\n", result);
            if (result != MATCH.nomatch)
                return;

            Type tb = t.toBasetype();
            Type typeb = e.type.toBasetype();

            // Look for pointers to functions where the functions are overloaded.
            if (typeb.ty == Tpointer && typeb.nextOf().ty == Tfunction &&
                (tb.ty == Tpointer || tb.ty == Tdelegate) && tb.nextOf().ty == Tfunction)
            {
                if (FuncDeclaration f = e.var.isFuncDeclaration())
                {
                    f = f.overloadExactMatch(tb.nextOf());
                    if (f)
                    {
                        if ((tb.ty == Tdelegate && (f.needThis() || f.isNested())) ||
                            (tb.ty == Tpointer && !(f.needThis() || f.isNested())))
                        {
                            result = MATCH.exact;
                        }
                    }
                }
            }
            //printf("\tresult = %d\n", result);
        }

        override void visit(DelegateExp e)
        {
            version (none)
            {
                printf("DelegateExp::implicitConvTo(this=%s, type=%s, t=%s)\n", e.toChars(), e.type.toChars(), t.toChars());
            }
            result = e.type.implicitConvTo(t);
            if (result != MATCH.nomatch)
                return;

            Type tb = t.toBasetype();
            Type typeb = e.type.toBasetype();

            // Look for pointers to functions where the functions are overloaded.
            if (typeb.ty == Tdelegate && tb.ty == Tdelegate)
            {
                if (e.func && e.func.overloadExactMatch(tb.nextOf()))
                    result = MATCH.exact;
            }
        }

        override void visit(FuncExp e)
        {
            //printf("FuncExp::implicitConvTo type = %p %s, t = %s\n", e.type, e.type ? e.type.toChars() : NULL, t.toChars());
            MATCH m = e.matchType(t, null, null, 1);
            if (m > MATCH.nomatch)
            {
                result = m;
                return;
            }
            visit(cast(Expression)e);
        }

        override void visit(AndExp e)
        {
            visit(cast(Expression)e);
            if (result != MATCH.nomatch)
                return;

            MATCH m1 = e.e1.implicitConvTo(t);
            MATCH m2 = e.e2.implicitConvTo(t);

            // Pick the worst match
            result = (m1 < m2) ? m1 : m2;
        }

        override void visit(OrExp e)
        {
            visit(cast(Expression)e);
            if (result != MATCH.nomatch)
                return;

            MATCH m1 = e.e1.implicitConvTo(t);
            MATCH m2 = e.e2.implicitConvTo(t);

            // Pick the worst match
            result = (m1 < m2) ? m1 : m2;
        }

        override void visit(XorExp e)
        {
            visit(cast(Expression)e);
            if (result != MATCH.nomatch)
                return;

            MATCH m1 = e.e1.implicitConvTo(t);
            MATCH m2 = e.e2.implicitConvTo(t);

            // Pick the worst match
            result = (m1 < m2) ? m1 : m2;
        }

        override void visit(CondExp e)
        {
            MATCH m1 = e.e1.implicitConvTo(t);
            MATCH m2 = e.e2.implicitConvTo(t);
            //printf("CondExp: m1 %d m2 %d\n", m1, m2);

            // Pick the worst match
            result = (m1 < m2) ? m1 : m2;
        }

        override void visit(CommaExp e)
        {
            e.e2.accept(this);
        }

        override void visit(CastExp e)
        {
            version (none)
            {
                printf("CastExp::implicitConvTo(this=%s, type=%s, t=%s)\n", e.toChars(), e.type.toChars(), t.toChars());
            }
            result = e.type.implicitConvTo(t);
            if (result != MATCH.nomatch)
                return;

            if (t.isintegral() && e.e1.type.isintegral() && e.e1.implicitConvTo(t) != MATCH.nomatch)
                result = MATCH.convert;
            else
                visit(cast(Expression)e);
        }

        override void visit(NewExp e)
        {
            version (none)
            {
                printf("NewExp::implicitConvTo(this=%s, type=%s, t=%s)\n", e.toChars(), e.type.toChars(), t.toChars());
            }
            visit(cast(Expression)e);
            if (result != MATCH.nomatch)
                return;

            /* Calling new() is like calling a pure function. We can implicitly convert the
             * return from new() to t using the same algorithm as in CallExp, with the function
             * 'arguments' being:
             *    thisexp
             *    newargs
             *    arguments
             *    .init
             * 'member' need to be pure.
             */

            /* See if fail only because of mod bits
             */
            if (e.type.immutableOf().implicitConvTo(t.immutableOf()) == MATCH.nomatch)
                return;

            /* Get mod bits of what we're converting to
             */
            Type tb = t.toBasetype();
            MOD mod = tb.mod;
            if (Type ti = getIndirection(t))
                mod = ti.mod;
            static if (LOG)
            {
                printf("mod = x%x\n", mod);
            }
            if (mod & MODFlags.wild)
                return; // not sure what to do with this

            /* Apply mod bits to each argument,
             * and see if we can convert the argument to the modded type
             */

            if (e.thisexp)
            {
                /* Treat 'this' as just another function argument
                 */
                Type targ = e.thisexp.type;
                if (targ.constConv(targ.castMod(mod)) == MATCH.nomatch)
                    return;
            }

            /* Check call to 'member'
             */
            if (e.member)
            {
                FuncDeclaration fd = e.member;
                if (fd.errors || fd.type.ty != Tfunction)
                    return; // error
                TypeFunction tf = fd.type.isTypeFunction();
                if (tf.purity == PURE.impure)
                    return; // impure

                if (e.type.immutableOf().implicitConvTo(t) < MATCH.constant && e.type.addMod(MODFlags.shared_).implicitConvTo(t) < MATCH.constant && e.type.implicitConvTo(t.addMod(MODFlags.shared_)) < MATCH.constant)
                {
                    return;
                }
                // Allow a conversion to immutable type, or
                // conversions of mutable types between thread-local and shared.

                Expressions* args = e.arguments;

                size_t nparams = tf.parameterList.length;
                // if TypeInfoArray was prepended
                size_t j = tf.isDstyleVariadic();
                for (size_t i = j; i < e.arguments.dim; ++i)
                {
                    Expression earg = (*args)[i];
                    Type targ = earg.type.toBasetype();
                    static if (LOG)
                    {
                        printf("[%d] earg: %s, targ: %s\n", cast(int)i, earg.toChars(), targ.toChars());
                    }
                    if (i - j < nparams)
                    {
                        Parameter fparam = tf.parameterList[i - j];
                        if (fparam.storageClass & STC.lazy_)
                            return; // not sure what to do with this
                        Type tparam = fparam.type;
                        if (!tparam)
                            continue;
                        if (fparam.isReference())
                        {
                            if (targ.constConv(tparam.castMod(mod)) == MATCH.nomatch)
                                return;
                            continue;
                        }
                    }
                    static if (LOG)
                    {
                        printf("[%d] earg: %s, targm: %s\n", cast(int)i, earg.toChars(), targ.addMod(mod).toChars());
                    }
                    if (implicitMod(earg, targ, mod) == MATCH.nomatch)
                        return;
                }
            }

            /* If no 'member', then construction is by simple assignment,
             * and just straight check 'arguments'
             */
            if (!e.member && e.arguments)
            {
                for (size_t i = 0; i < e.arguments.dim; ++i)
                {
                    Expression earg = (*e.arguments)[i];
                    if (!earg) // https://issues.dlang.org/show_bug.cgi?id=14853
                               // if it's on overlapped field
                        continue;
                    Type targ = earg.type.toBasetype();
                    static if (LOG)
                    {
                        printf("[%d] earg: %s, targ: %s\n", cast(int)i, earg.toChars(), targ.toChars());
                        printf("[%d] earg: %s, targm: %s\n", cast(int)i, earg.toChars(), targ.addMod(mod).toChars());
                    }
                    if (implicitMod(earg, targ, mod) == MATCH.nomatch)
                        return;
                }
            }

            /* Consider the .init expression as an argument
             */
            Type ntb = e.newtype.toBasetype();
            if (ntb.ty == Tarray)
                ntb = ntb.nextOf().toBasetype();
            if (auto ts = ntb.isTypeStruct())
            {
                // Don't allow nested structs - uplevel reference may not be convertible
                StructDeclaration sd = ts.sym;
                sd.size(e.loc); // resolve any forward references
                if (sd.isNested())
                    return;
            }
            if (ntb.isZeroInit(e.loc))
            {
                /* Zeros are implicitly convertible, except for special cases.
                 */
                if (auto tc = ntb.isTypeClass())
                {
                    /* With new() must look at the class instance initializer.
                     */
                    ClassDeclaration cd = tc.sym;

                    cd.size(e.loc); // resolve any forward references

                    if (cd.isNested())
                        return; // uplevel reference may not be convertible

                    assert(!cd.isInterfaceDeclaration());

                    struct ClassCheck
                    {
                        extern (C++) static bool convertible(Expression e, ClassDeclaration cd, MOD mod)
                        {
                            for (size_t i = 0; i < cd.fields.dim; i++)
                            {
                                VarDeclaration v = cd.fields[i];
                                Initializer _init = v._init;
                                if (_init)
                                {
                                    if (_init.isVoidInitializer())
                                    {
                                    }
                                    else if (ExpInitializer ei = _init.isExpInitializer())
                                    {
                                        // https://issues.dlang.org/show_bug.cgi?id=21319
                                        // This is to prevent re-analyzing the same expression
                                        // over and over again.
                                        if (ei.exp == e)
                                            return false;
                                        Type tb = v.type.toBasetype();
                                        if (implicitMod(ei.exp, tb, mod) == MATCH.nomatch)
                                            return false;
                                    }
                                    else
                                    {
                                        /* Enhancement: handle StructInitializer and ArrayInitializer
                                         */
                                        return false;
                                    }
                                }
                                else if (!v.type.isZeroInit(e.loc))
                                    return false;
                            }
                            return cd.baseClass ? convertible(e, cd.baseClass, mod) : true;
                        }
                    }

                    if (!ClassCheck.convertible(e, cd, mod))
                        return;
                }
            }
            else
            {
                Expression earg = e.newtype.defaultInitLiteral(e.loc);
                Type targ = e.newtype.toBasetype();

                if (implicitMod(earg, targ, mod) == MATCH.nomatch)
                    return;
            }

            /* Success
             */
            result = MATCH.constant;
        }

        override void visit(SliceExp e)
        {
            //printf("SliceExp::implicitConvTo e = %s, type = %s\n", e.toChars(), e.type.toChars());
            visit(cast(Expression)e);
            if (result != MATCH.nomatch)
                return;

            Type tb = t.toBasetype();
            Type typeb = e.type.toBasetype();

            if (tb.ty == Tsarray && typeb.ty == Tarray)
            {
                typeb = toStaticArrayType(e);
                if (typeb)
                {
                    // Try: T[] -> T[dim]
                    // (Slice with compile-time known boundaries to static array)
                    result = typeb.implicitConvTo(t);
                    if (result > MATCH.convert)
                        result = MATCH.convert; // match with implicit conversion at most
                }
                return;
            }

            /* If the only reason it won't convert is because of the mod bits,
             * then test for conversion by seeing if e1 can be converted with those
             * same mod bits.
             */
            Type t1b = e.e1.type.toBasetype();
            if (tb.ty == Tarray && typeb.equivalent(tb))
            {
                Type tbn = tb.nextOf();
                Type tx = null;

                /* If e.e1 is dynamic array or pointer, the uniqueness of e.e1
                 * is equivalent with the uniqueness of the referred data. And in here
                 * we can have arbitrary typed reference for that.
                 */
                if (t1b.ty == Tarray)
                    tx = tbn.arrayOf();
                if (t1b.ty == Tpointer)
                    tx = tbn.pointerTo();

                /* If e.e1 is static array, at least it should be an rvalue.
                 * If not, e.e1 is a reference, and its uniqueness does not link
                 * to the uniqueness of the referred data.
                 */
                if (t1b.ty == Tsarray && !e.e1.isLvalue())
                    tx = tbn.sarrayOf(t1b.size() / tbn.size());

                if (tx)
                {
                    result = e.e1.implicitConvTo(tx);
                    if (result > MATCH.constant) // Match level is MATCH.constant at best.
                        result = MATCH.constant;
                }
            }

            // Enhancement 10724
            if (tb.ty == Tpointer && e.e1.op == TOK.string_)
                e.e1.accept(this);
        }

        override void visit(TupleExp e)
        {
            result = e.type.implicitConvTo(t);
            if (result != MATCH.nomatch)
                return;

            /* If target type is a tuple of same length, test conversion of
             * each expression to the corresponding type in the tuple.
             */
            TypeTuple totuple = t.isTypeTuple();
            if (totuple && e.exps.length == totuple.arguments.length)
            {
                result = MATCH.exact;
                foreach (i, ex; *e.exps)
                {
                    auto to = (*totuple.arguments)[i].type;
                    MATCH mi = ex.implicitConvTo(to);
                    if (mi < result)
                        result = mi;
                }
            }
        }
    }

    scope ImplicitConvTo v = new ImplicitConvTo(t);
    e.accept(v);
    return v.result;
}

/**
 * Same as implicitConvTo(); except follow C11 rules, which are quite a bit
 * more permissive than D.
 * C11 6.3 and 6.5.16.1
 * Params:
 *   e = Expression that is to be casted
 *   t = Expected resulting type
 * Returns:
 *   The `MATCH` level between `e.type` and `t`.
 */
MATCH cimplicitConvTo(Expression e, Type t)
{
    Type tb = t.toBasetype();
    Type typeb = e.type.toBasetype();

    if (tb.equals(typeb))
        return MATCH.exact;
    if ((typeb.isintegral() || typeb.isfloating()) &&
        (tb.isintegral() || tb.isfloating()))
        return MATCH.convert;
    if (tb.ty == Tpointer && typeb.isintegral()) // C11 6.3.2.3-5
        return MATCH.convert;
    if (tb.isintegral() && typeb.ty == Tpointer) // C11 6.3.2.3-6
        return MATCH.convert;
    if (tb.ty == Tpointer && typeb.ty == Tpointer)
    {
        if (tb.isTypePointer().next.ty == Tvoid ||
            typeb.isTypePointer().next.ty == Tvoid)
            return MATCH.convert;       // convert to/from void* C11 6.3.2.3-1
    }

    return implicitConvTo(e, t);
}

/*****************************************
 */
Type toStaticArrayType(SliceExp e)
{
    if (e.lwr && e.upr)
    {
        // For the following code to work, e should be optimized beforehand.
        // (eg. $ in lwr and upr should be already resolved, if possible)
        Expression lwr = e.lwr.optimize(WANTvalue);
        Expression upr = e.upr.optimize(WANTvalue);
        if (lwr.isConst() && upr.isConst())
        {
            size_t len = cast(size_t)(upr.toUInteger() - lwr.toUInteger());
            return e.type.toBasetype().nextOf().sarrayOf(len);
        }
    }
    else
    {
        Type t1b = e.e1.type.toBasetype();
        if (t1b.ty == Tsarray)
            return t1b;
    }
    return null;
}

/**************************************
 * Do an explicit cast.
 * Assume that the expression `e` does not have any indirections.
 * (Parameter 'att' is used to stop 'alias this' recursion)
 */
Expression castTo(Expression e, Scope* sc, Type t, Type att = null)
{
    extern (C++) final class CastTo : Visitor
    {
        alias visit = Visitor.visit;
    public:
        Type t;
        Scope* sc;
        Expression result;

        extern (D) this(Scope* sc, Type t)
        {
            this.sc = sc;
            this.t = t;
        }

        override void visit(Expression e)
        {
            //printf("Expression::castTo(this=%s, t=%s)\n", e.toChars(), t.toChars());
            version (none)
            {
                printf("Expression::castTo(this=%s, type=%s, t=%s)\n", e.toChars(), e.type.toChars(), t.toChars());
            }
            if (e.type.equals(t))
            {
                result = e;
                return;
            }
            if (e.op == TOK.variable)
            {
                VarDeclaration v = (cast(VarExp)e).var.isVarDeclaration();
                if (v && v.storage_class & STC.manifest)
                {
                    result = e.ctfeInterpret();
                    /* https://issues.dlang.org/show_bug.cgi?id=18236
                     *
                     * The expression returned by ctfeInterpret points
                     * to the line where the manifest constant was declared
                     * so we need to update the location before trying to cast
                     */
                    result.loc = e.loc;
                    result = result.castTo(sc, t);
                    return;
                }
            }

            Type tob = t.toBasetype();
            Type t1b = e.type.toBasetype();
            if (tob.equals(t1b))
            {
                result = e.copy(); // because of COW for assignment to e.type
                result.type = t;
                return;
            }

            /* Make semantic error against invalid cast between concrete types.
             * Assume that 'e' is never be any placeholder expressions.
             * The result of these checks should be consistent with CastExp::toElem().
             */

            // Fat Value types
            const(bool) tob_isFV = (tob.ty == Tstruct || tob.ty == Tsarray || tob.ty == Tvector);
            const(bool) t1b_isFV = (t1b.ty == Tstruct || t1b.ty == Tsarray || t1b.ty == Tvector);

            // Fat Reference types
            const(bool) tob_isFR = (tob.ty == Tarray || tob.ty == Tdelegate);
            const(bool) t1b_isFR = (t1b.ty == Tarray || t1b.ty == Tdelegate);

            // Reference types
            const(bool) tob_isR = (tob_isFR || tob.ty == Tpointer || tob.ty == Taarray || tob.ty == Tclass);
            const(bool) t1b_isR = (t1b_isFR || t1b.ty == Tpointer || t1b.ty == Taarray || t1b.ty == Tclass);

            // Arithmetic types (== valueable basic types)
            const(bool) tob_isA = ((tob.isintegral() || tob.isfloating()) && tob.ty != Tvector);
            const(bool) t1b_isA = ((t1b.isintegral() || t1b.isfloating()) && t1b.ty != Tvector);

            // Try casting the alias this member.
            // Return the expression if it succeeds, null otherwise.
            Expression tryAliasThisCast()
            {
                if (isRecursiveAliasThis(att, t1b))
                    return null;

                /* Forward the cast to our alias this member, rewrite to:
                 *   cast(to)e1.aliasthis
                 */
                auto exp = resolveAliasThis(sc, e);
                const errors = global.startGagging();
                exp = castTo(exp, sc, t, att);
                return global.endGagging(errors) ? null : exp;
            }

            bool hasAliasThis;
            if (AggregateDeclaration t1ad = isAggregate(t1b))
            {
                AggregateDeclaration toad = isAggregate(tob);
                if (t1ad != toad && t1ad.aliasthis)
                {
                    if (t1b.ty == Tclass && tob.ty == Tclass)
                    {
                        ClassDeclaration t1cd = t1b.isClassHandle();
                        ClassDeclaration tocd = tob.isClassHandle();
                        int offset;
                        if (tocd.isBaseOf(t1cd, &offset))
                            goto Lok;
                    }
                    hasAliasThis = true;
                }
            }
            else if (tob.ty == Tvector && t1b.ty != Tvector)
            {
                //printf("test1 e = %s, e.type = %s, tob = %s\n", e.toChars(), e.type.toChars(), tob.toChars());
                TypeVector tv = tob.isTypeVector();
                result = new CastExp(e.loc, e, tv.elementType());
                result = new VectorExp(e.loc, result, tob);
                result = result.expressionSemantic(sc);
                return;
            }
            else if (tob.ty != Tvector && t1b.ty == Tvector)
            {
                // T[n] <-- __vector(U[m])
                if (tob.ty == Tsarray)
                {
                    if (t1b.size(e.loc) == tob.size(e.loc))
                        goto Lok;
                }
                goto Lfail;
            }
            else if (t1b.implicitConvTo(tob) == MATCH.constant && t.equals(e.type.constOf()))
            {
                result = e.copy();
                result.type = t;
                return;
            }

            // arithmetic values vs. other arithmetic values
            // arithmetic values vs. T*
            if (tob_isA && (t1b_isA || t1b.ty == Tpointer) || t1b_isA && (tob_isA || tob.ty == Tpointer))
            {
                goto Lok;
            }

            // arithmetic values vs. references or fat values
            if (tob_isA && (t1b_isR || t1b_isFV) || t1b_isA && (tob_isR || tob_isFV))
            {
                goto Lfail;
            }

            // Bugzlla 3133: A cast between fat values is possible only when the sizes match.
            if (tob_isFV && t1b_isFV)
            {
                if (hasAliasThis)
                {
                    result = tryAliasThisCast();
                    if (result)
                        return;
                }

                if (t1b.size(e.loc) == tob.size(e.loc))
                    goto Lok;

                auto ts = toAutoQualChars(e.type, t);
                e.error("cannot cast expression `%s` of type `%s` to `%s` because of different sizes",
                    e.toChars(), ts[0], ts[1]);
                result = ErrorExp.get();
                return;
            }

            // Fat values vs. null or references
            if (tob_isFV && (t1b.ty == Tnull || t1b_isR) || t1b_isFV && (tob.ty == Tnull || tob_isR))
            {
                if (tob.ty == Tpointer && t1b.ty == Tsarray)
                {
                    // T[n] sa;
                    // cast(U*)sa; // ==> cast(U*)sa.ptr;
                    result = new AddrExp(e.loc, e, t);
                    return;
                }
                if (tob.ty == Tarray && t1b.ty == Tsarray)
                {
                    // T[n] sa;
                    // cast(U[])sa; // ==> cast(U[])sa[];
                    const fsize = t1b.nextOf().size();
                    const tsize = tob.nextOf().size();
                    if (fsize != tsize)
                    {
                        const dim = t1b.isTypeSArray().dim.toInteger();
                        if (tsize == 0 || (dim * fsize) % tsize != 0)
                        {
                            e.error("cannot cast expression `%s` of type `%s` to `%s` since sizes don't line up",
                                    e.toChars(), e.type.toChars(), t.toChars());
                            result = ErrorExp.get();
                            return;
                        }
                    }
                    goto Lok;
                }
                goto Lfail;
            }

            /* For references, any reinterpret casts are allowed to same 'ty' type.
             *      T* to U*
             *      R1 function(P1) to R2 function(P2)
             *      R1 delegate(P1) to R2 delegate(P2)
             *      T[] to U[]
             *      V1[K1] to V2[K2]
             *      class/interface A to B  (will be a dynamic cast if possible)
             */
            if (tob.ty == t1b.ty && tob_isR && t1b_isR)
                goto Lok;

            // typeof(null) <-- non-null references or values
            if (tob.ty == Tnull && t1b.ty != Tnull)
                goto Lfail; // https://issues.dlang.org/show_bug.cgi?id=14629
            // typeof(null) --> non-null references or arithmetic values
            if (t1b.ty == Tnull && tob.ty != Tnull)
                goto Lok;

            // Check size mismatch of references.
            // Tarray and Tdelegate are (void*).sizeof*2, but others have (void*).sizeof.
            if (tob_isFR && t1b_isR || t1b_isFR && tob_isR)
            {
                if (tob.ty == Tpointer && t1b.ty == Tarray)
                {
                    // T[] da;
                    // cast(U*)da; // ==> cast(U*)da.ptr;
                    goto Lok;
                }
                if (tob.ty == Tpointer && t1b.ty == Tdelegate)
                {
                    // void delegate() dg;
                    // cast(U*)dg; // ==> cast(U*)dg.ptr;
                    // Note that it happens even when U is a Tfunction!
                    e.deprecation("casting from %s to %s is deprecated", e.type.toChars(), t.toChars());
                    goto Lok;
                }
                goto Lfail;
            }

            if (t1b.ty == Tvoid && tob.ty != Tvoid)
            {
            Lfail:
                /* if the cast cannot be performed, maybe there is an alias
                 * this that can be used for casting.
                 */
                if (hasAliasThis)
                {
                    result = tryAliasThisCast();
                    if (result)
                        return;
                }
                e.error("cannot cast expression `%s` of type `%s` to `%s`", e.toChars(), e.type.toChars(), t.toChars());
                result = ErrorExp.get();
                return;
            }

        Lok:
            result = new CastExp(e.loc, e, t);
            result.type = t; // Don't call semantic()
            //printf("Returning: %s\n", result.toChars());
        }

        override void visit(ErrorExp e)
        {
            result = e;
        }

        override void visit(RealExp e)
        {
            if (!e.type.equals(t))
            {
                if ((e.type.isreal() && t.isreal()) || (e.type.isimaginary() && t.isimaginary()))
                {
                    result = e.copy();
                    result.type = t;
                }
                else
                    visit(cast(Expression)e);
                return;
            }
            result = e;
        }

        override void visit(ComplexExp e)
        {
            if (!e.type.equals(t))
            {
                if (e.type.iscomplex() && t.iscomplex())
                {
                    result = e.copy();
                    result.type = t;
                }
                else
                    visit(cast(Expression)e);
                return;
            }
            result = e;
        }

        override void visit(StructLiteralExp e)
        {
            visit(cast(Expression)e);
            if (result.op == TOK.structLiteral)
                (cast(StructLiteralExp)result).stype = t; // commit type
        }

        override void visit(StringExp e)
        {
            /* This follows copy-on-write; any changes to 'this'
             * will result in a copy.
             * The this.string member is considered immutable.
             */
            int copied = 0;

            //printf("StringExp::castTo(t = %s), '%s' committed = %d\n", t.toChars(), e.toChars(), e.committed);

            if (!e.committed && t.ty == Tpointer && t.nextOf().ty == Tvoid)
            {
                e.error("cannot convert string literal to `void*`");
                result = ErrorExp.get();
                return;
            }

            StringExp se = e;
            if (!e.committed)
            {
                se = cast(StringExp)e.copy();
                se.committed = 1;
                copied = 1;
            }

            if (e.type.equals(t))
            {
                result = se;
                return;
            }

            Type tb = t.toBasetype();
            Type typeb = e.type.toBasetype();

            //printf("\ttype = %s\n", e.type.toChars());
            if (tb.ty == Tdelegate && typeb.ty != Tdelegate)
            {
                visit(cast(Expression)e);
                return;
            }

            if (typeb.equals(tb))
            {
                if (!copied)
                {
                    se = cast(StringExp)e.copy();
                    copied = 1;
                }
                se.type = t;
                result = se;
                return;
            }

            /* Handle reinterpret casts:
             *  cast(wchar[3])"abcd"c --> [\u6261, \u6463, \u0000]
             *  cast(wchar[2])"abcd"c --> [\u6261, \u6463]
             *  cast(wchar[1])"abcd"c --> [\u6261]
             *  cast(char[4])"a" --> ['a', 0, 0, 0]
             */
            if (e.committed && tb.ty == Tsarray && typeb.ty == Tarray)
            {
                se = cast(StringExp)e.copy();
                d_uns64 szx = tb.nextOf().size();
                assert(szx <= 255);
                se.sz = cast(ubyte)szx;
                se.len = cast(size_t)tb.isTypeSArray().dim.toInteger();
                se.committed = 1;
                se.type = t;

                /* If larger than source, pad with zeros.
                 */
                const fullSize = (se.len + 1) * se.sz; // incl. terminating 0
                if (fullSize > (e.len + 1) * e.sz)
                {
                    void* s = mem.xmalloc(fullSize);
                    const srcSize = e.len * e.sz;
                    const data = se.peekData();
                    memcpy(s, data.ptr, srcSize);
                    memset(s + srcSize, 0, fullSize - srcSize);
                    se.setData(s, se.len, se.sz);
                }
                result = se;
                return;
            }

            if (tb.ty != Tsarray && tb.ty != Tarray && tb.ty != Tpointer)
            {
                if (!copied)
                {
                    se = cast(StringExp)e.copy();
                    copied = 1;
                }
                goto Lcast;
            }
            if (typeb.ty != Tsarray && typeb.ty != Tarray && typeb.ty != Tpointer)
            {
                if (!copied)
                {
                    se = cast(StringExp)e.copy();
                    copied = 1;
                }
                goto Lcast;
            }

            if (typeb.nextOf().size() == tb.nextOf().size())
            {
                if (!copied)
                {
                    se = cast(StringExp)e.copy();
                    copied = 1;
                }
                if (tb.ty == Tsarray)
                    goto L2; // handle possible change in static array dimension
                se.type = t;
                result = se;
                return;
            }

            if (e.committed)
                goto Lcast;

            auto X(T, U)(T tf, U tt)
            {
                return (cast(int)tf * 256 + cast(int)tt);
            }

            {
                OutBuffer buffer;
                size_t newlen = 0;
                int tfty = typeb.nextOf().toBasetype().ty;
                int ttty = tb.nextOf().toBasetype().ty;
                switch (X(tfty, ttty))
                {
                case X(Tchar, Tchar):
                case X(Twchar, Twchar):
                case X(Tdchar, Tdchar):
                    break;

                case X(Tchar, Twchar):
                    for (size_t u = 0; u < e.len;)
                    {
                        dchar c;
                        if (const s = utf_decodeChar(se.peekString(), u, c))
                            e.error("%.*s", cast(int)s.length, s.ptr);
                        else
                            buffer.writeUTF16(c);
                    }
                    newlen = buffer.length / 2;
                    buffer.writeUTF16(0);
                    goto L1;

                case X(Tchar, Tdchar):
                    for (size_t u = 0; u < e.len;)
                    {
                        dchar c;
                        if (const s = utf_decodeChar(se.peekString(), u, c))
                            e.error("%.*s", cast(int)s.length, s.ptr);
                        buffer.write4(c);
                        newlen++;
                    }
                    buffer.write4(0);
                    goto L1;

                case X(Twchar, Tchar):
                    for (size_t u = 0; u < e.len;)
                    {
                        dchar c;
                        if (const s = utf_decodeWchar(se.peekWstring(), u, c))
                            e.error("%.*s", cast(int)s.length, s.ptr);
                        else
                            buffer.writeUTF8(c);
                    }
                    newlen = buffer.length;
                    buffer.writeUTF8(0);
                    goto L1;

                case X(Twchar, Tdchar):
                    for (size_t u = 0; u < e.len;)
                    {
                        dchar c;
                        if (const s = utf_decodeWchar(se.peekWstring(), u, c))
                            e.error("%.*s", cast(int)s.length, s.ptr);
                        buffer.write4(c);
                        newlen++;
                    }
                    buffer.write4(0);
                    goto L1;

                case X(Tdchar, Tchar):
                    for (size_t u = 0; u < e.len; u++)
                    {
                        uint c = se.peekDstring()[u];
                        if (!utf_isValidDchar(c))
                            e.error("invalid UCS-32 char \\U%08x", c);
                        else
                            buffer.writeUTF8(c);
                        newlen++;
                    }
                    newlen = buffer.length;
                    buffer.writeUTF8(0);
                    goto L1;

                case X(Tdchar, Twchar):
                    for (size_t u = 0; u < e.len; u++)
                    {
                        uint c = se.peekDstring()[u];
                        if (!utf_isValidDchar(c))
                            e.error("invalid UCS-32 char \\U%08x", c);
                        else
                            buffer.writeUTF16(c);
                        newlen++;
                    }
                    newlen = buffer.length / 2;
                    buffer.writeUTF16(0);
                    goto L1;

                L1:
                    if (!copied)
                    {
                        se = cast(StringExp)e.copy();
                        copied = 1;
                    }

                    {
                        d_uns64 szx = tb.nextOf().size();
                        assert(szx <= 255);
                        se.setData(buffer.extractSlice().ptr, newlen, cast(ubyte)szx);
                    }
                    break;

                default:
                    assert(typeb.nextOf().size() != tb.nextOf().size());
                    goto Lcast;
                }
            }
        L2:
            assert(copied);

            // See if need to truncate or extend the literal
            if (auto tsa = tb.isTypeSArray())
            {
                size_t dim2 = cast(size_t)tsa.dim.toInteger();
                //printf("dim from = %d, to = %d\n", (int)se.len, (int)dim2);

                // Changing dimensions
                if (dim2 != se.len)
                {
                    // Copy when changing the string literal
                    const newsz = se.sz;
                    const d = (dim2 < se.len) ? dim2 : se.len;
                    void* s = mem.xmalloc((dim2 + 1) * newsz);
                    memcpy(s, se.peekData().ptr, d * newsz);
                    // Extend with 0, add terminating 0
                    memset(s + d * newsz, 0, (dim2 + 1 - d) * newsz);
                    se.setData(s, dim2, newsz);
                }
            }
            se.type = t;
            result = se;
            return;

        Lcast:
            result = new CastExp(e.loc, se, t);
            result.type = t; // so semantic() won't be run on e
        }

        override void visit(AddrExp e)
        {
            version (none)
            {
                printf("AddrExp::castTo(this=%s, type=%s, t=%s)\n", e.toChars(), e.type.toChars(), t.toChars());
            }
            result = e;

            Type tb = t.toBasetype();
            Type typeb = e.type.toBasetype();

            if (tb.equals(typeb))
            {
                result = e.copy();
                result.type = t;
                return;
            }

            // Look for pointers to functions where the functions are overloaded.
            if (e.e1.op == TOK.overloadSet &&
                (tb.ty == Tpointer || tb.ty == Tdelegate) && tb.nextOf().ty == Tfunction)
            {
                OverExp eo = cast(OverExp)e.e1;
                FuncDeclaration f = null;
                for (size_t i = 0; i < eo.vars.a.dim; i++)
                {
                    auto s = eo.vars.a[i];
                    auto f2 = s.isFuncDeclaration();
                    assert(f2);
                    if (f2.overloadExactMatch(tb.nextOf()))
                    {
                        if (f)
                        {
                            /* Error if match in more than one overload set,
                             * even if one is a 'better' match than the other.
                             */
                            ScopeDsymbol.multiplyDefined(e.loc, f, f2);
                        }
                        else
                            f = f2;
                    }
                }
                if (f)
                {
                    f.tookAddressOf++;
                    auto se = new SymOffExp(e.loc, f, 0, false);
                    auto se2 = se.expressionSemantic(sc);
                    // Let SymOffExp::castTo() do the heavy lifting
                    visit(se2);
                    return;
                }
            }

            if (e.e1.op == TOK.variable &&
                typeb.ty == Tpointer && typeb.nextOf().ty == Tfunction &&
                tb.ty == Tpointer && tb.nextOf().ty == Tfunction)
            {
                auto ve = cast(VarExp)e.e1;
                auto f = ve.var.isFuncDeclaration();
                if (f)
                {
                    assert(f.isImportedSymbol());
                    f = f.overloadExactMatch(tb.nextOf());
                    if (f)
                    {
                        result = new VarExp(e.loc, f, false);
                        result.type = f.type;
                        result = new AddrExp(e.loc, result, t);
                        return;
                    }
                }
            }

            if (auto f = isFuncAddress(e))
            {
                if (f.checkForwardRef(e.loc))
                {
                    result = ErrorExp.get();
                    return;
                }
            }

            visit(cast(Expression)e);
        }

        override void visit(TupleExp e)
        {
            if (e.type.equals(t))
            {
                result = e;
                return;
            }

            /* If target type is a tuple of same length, cast each expression to
             * the corresponding type in the tuple.
             */
            TypeTuple totuple;
            if (auto tt = t.isTypeTuple())
                totuple = e.exps.length == tt.arguments.length ? tt : null;

            TupleExp te = e.copy().isTupleExp();
            te.e0 = e.e0 ? e.e0.copy() : null;
            te.exps = e.exps.copy();
            for (size_t i = 0; i < te.exps.dim; i++)
            {
                Expression ex = (*te.exps)[i];
                ex = ex.castTo(sc, totuple ? (*totuple.arguments)[i].type : t);
                (*te.exps)[i] = ex;
            }
            result = te;

            /* Questionable behavior: In here, result.type is not set to t.
             * Therefoe:
             *  TypeTuple!(int, int) values;
             *  auto values2 = cast(long)values;
             *  // typeof(values2) == TypeTuple!(int, int) !!
             *
             * Only when the casted tuple is immediately expanded, it would work.
             *  auto arr = [cast(long)values];
             *  // typeof(arr) == long[]
             */
        }

        override void visit(ArrayLiteralExp e)
        {
            version (none)
            {
                printf("ArrayLiteralExp::castTo(this=%s, type=%s, => %s)\n", e.toChars(), e.type.toChars(), t.toChars());
            }

            ArrayLiteralExp ae = e;

            Type tb = t.toBasetype();
            if (tb.ty == Tarray && global.params.useDIP1000 == FeatureState.enabled)
            {
                if (checkArrayLiteralEscape(sc, ae, false))
                {
                    result = ErrorExp.get();
                    return;
                }
            }

            if (e.type == t)
            {
                result = e;
                return;
            }
            Type typeb = e.type.toBasetype();

            if ((tb.ty == Tarray || tb.ty == Tsarray) &&
                (typeb.ty == Tarray || typeb.ty == Tsarray))
            {
                if (tb.nextOf().toBasetype().ty == Tvoid && typeb.nextOf().toBasetype().ty != Tvoid)
                {
                    // Don't do anything to cast non-void[] to void[]
                }
                else if (typeb.ty == Tsarray && typeb.nextOf().toBasetype().ty == Tvoid)
                {
                    // Don't do anything for casting void[n] to others
                }
                else
                {
                    if (auto tsa = tb.isTypeSArray())
                    {
                        if (e.elements.dim != tsa.dim.toInteger())
                            goto L1;
                    }

                    ae = cast(ArrayLiteralExp)e.copy();
                    if (e.basis)
                        ae.basis = e.basis.castTo(sc, tb.nextOf());
                    ae.elements = e.elements.copy();
                    for (size_t i = 0; i < e.elements.dim; i++)
                    {
                        Expression ex = (*e.elements)[i];
                        if (!ex)
                            continue;
                        ex = ex.castTo(sc, tb.nextOf());
                        (*ae.elements)[i] = ex;
                    }
                    ae.type = t;
                    result = ae;
                    return;
                }
            }
            else if (tb.ty == Tpointer && typeb.ty == Tsarray)
            {
                Type tp = typeb.nextOf().pointerTo();
                if (!tp.equals(ae.type))
                {
                    ae = cast(ArrayLiteralExp)e.copy();
                    ae.type = tp;
                }
            }
            else if (tb.ty == Tvector && (typeb.ty == Tarray || typeb.ty == Tsarray))
            {
                // Convert array literal to vector type
                TypeVector tv = tb.isTypeVector();
                TypeSArray tbase = tv.basetype.isTypeSArray();
                assert(tbase.ty == Tsarray);
                const edim = e.elements.dim;
                const tbasedim = tbase.dim.toInteger();
                if (edim > tbasedim)
                    goto L1;

                ae = e.copy().isArrayLiteralExp();
                ae.type = tbase; // https://issues.dlang.org/show_bug.cgi?id=12642
                ae.elements = e.elements.copy();
                Type telement = tv.elementType();
                foreach (i; 0 .. edim)
                {
                    Expression ex = (*e.elements)[i];
                    ex = ex.castTo(sc, telement);
                    (*ae.elements)[i] = ex;
                }
                // Fill in the rest with the default initializer
                ae.elements.setDim(cast(size_t)tbasedim);
                foreach (i; edim .. cast(size_t)tbasedim)
                {
                    Expression ex = typeb.nextOf.defaultInitLiteral(e.loc);
                    ex = ex.castTo(sc, telement);
                    (*ae.elements)[i] = ex;
                }
                Expression ev = new VectorExp(e.loc, ae, tb);
                ev = ev.expressionSemantic(sc);
                result = ev;
                return;
            }
        L1:
            visit(cast(Expression)ae);
        }

        override void visit(AssocArrayLiteralExp e)
        {
            //printf("AssocArrayLiteralExp::castTo(this=%s, type=%s, => %s)\n", e.toChars(), e.type.toChars(), t.toChars());
            if (e.type == t)
            {
                result = e;
                return;
            }

            Type tb = t.toBasetype();
            Type typeb = e.type.toBasetype();

            if (tb.ty == Taarray && typeb.ty == Taarray &&
                tb.nextOf().toBasetype().ty != Tvoid)
            {
                AssocArrayLiteralExp ae = cast(AssocArrayLiteralExp)e.copy();
                ae.keys = e.keys.copy();
                ae.values = e.values.copy();
                assert(e.keys.dim == e.values.dim);
                for (size_t i = 0; i < e.keys.dim; i++)
                {
                    Expression ex = (*e.values)[i];
                    ex = ex.castTo(sc, tb.nextOf());
                    (*ae.values)[i] = ex;

                    ex = (*e.keys)[i];
                    ex = ex.castTo(sc, tb.isTypeAArray().index);
                    (*ae.keys)[i] = ex;
                }
                ae.type = t;
                result = ae;
                return;
            }
            visit(cast(Expression)e);
        }

        override void visit(SymOffExp e)
        {
            version (none)
            {
                printf("SymOffExp::castTo(this=%s, type=%s, t=%s)\n", e.toChars(), e.type.toChars(), t.toChars());
            }
            if (e.type == t && !e.hasOverloads)
            {
                result = e;
                return;
            }

            Type tb = t.toBasetype();
            Type typeb = e.type.toBasetype();

            if (tb.equals(typeb))
            {
                result = e.copy();
                result.type = t;
                (cast(SymOffExp)result).hasOverloads = false;
                return;
            }

            // Look for pointers to functions where the functions are overloaded.
            if (e.hasOverloads &&
                typeb.ty == Tpointer && typeb.nextOf().ty == Tfunction &&
                (tb.ty == Tpointer || tb.ty == Tdelegate) && tb.nextOf().ty == Tfunction)
            {
                FuncDeclaration f = e.var.isFuncDeclaration();
                f = f ? f.overloadExactMatch(tb.nextOf()) : null;
                if (f)
                {
                    if (tb.ty == Tdelegate)
                    {
                        if (f.needThis() && hasThis(sc))
                        {
                            result = new DelegateExp(e.loc, new ThisExp(e.loc), f, false);
                            result = result.expressionSemantic(sc);
                        }
                        else if (f.needThis())
                        {
                            e.error("no `this` to create delegate for `%s`", f.toChars());
                            result = ErrorExp.get();
                            return;
                        }
                        else if (f.isNested())
                        {
                            result = new DelegateExp(e.loc, IntegerExp.literal!0, f, false);
                            result = result.expressionSemantic(sc);
                        }
                        else
                        {
                            e.error("cannot cast from function pointer to delegate");
                            result = ErrorExp.get();
                            return;
                        }
                    }
                    else
                    {
                        result = new SymOffExp(e.loc, f, 0, false);
                        result.type = t;
                    }
                    f.tookAddressOf++;
                    return;
                }
            }

            if (auto f = isFuncAddress(e))
            {
                if (f.checkForwardRef(e.loc))
                {
                    result = ErrorExp.get();
                    return;
                }
            }

            visit(cast(Expression)e);
        }

        override void visit(DelegateExp e)
        {
            version (none)
            {
                printf("DelegateExp::castTo(this=%s, type=%s, t=%s)\n", e.toChars(), e.type.toChars(), t.toChars());
            }
            __gshared const(char)* msg = "cannot form delegate due to covariant return type";

            Type tb = t.toBasetype();
            Type typeb = e.type.toBasetype();

            if (tb.equals(typeb) && !e.hasOverloads)
            {
                int offset;
                e.func.tookAddressOf++;
                if (e.func.tintro && e.func.tintro.nextOf().isBaseOf(e.func.type.nextOf(), &offset) && offset)
                    e.error("%s", msg);
                result = e.copy();
                result.type = t;
                return;
            }

            // Look for delegates to functions where the functions are overloaded.
            if (typeb.ty == Tdelegate && tb.ty == Tdelegate)
            {
                if (e.func)
                {
                    auto f = e.func.overloadExactMatch(tb.nextOf());
                    if (f)
                    {
                        int offset;
                        if (f.tintro && f.tintro.nextOf().isBaseOf(f.type.nextOf(), &offset) && offset)
                            e.error("%s", msg);
                        if (f != e.func)    // if address not already marked as taken
                            f.tookAddressOf++;
                        result = new DelegateExp(e.loc, e.e1, f, false, e.vthis2);
                        result.type = t;
                        return;
                    }
                    if (e.func.tintro)
                        e.error("%s", msg);
                }
            }

            if (auto f = isFuncAddress(e))
            {
                if (f.checkForwardRef(e.loc))
                {
                    result = ErrorExp.get();
                    return;
                }
            }

            visit(cast(Expression)e);
        }

        override void visit(FuncExp e)
        {
            //printf("FuncExp::castTo type = %s, t = %s\n", e.type.toChars(), t.toChars());
            FuncExp fe;
            if (e.matchType(t, sc, &fe, 1) > MATCH.nomatch)
            {
                result = fe;
                return;
            }
            visit(cast(Expression)e);
        }

        override void visit(CondExp e)
        {
            if (!e.type.equals(t))
            {
                result = new CondExp(e.loc, e.econd, e.e1.castTo(sc, t), e.e2.castTo(sc, t));
                result.type = t;
                return;
            }
            result = e;
        }

        override void visit(CommaExp e)
        {
            Expression e2c = e.e2.castTo(sc, t);

            if (e2c != e.e2)
            {
                result = new CommaExp(e.loc, e.e1, e2c);
                result.type = e2c.type;
            }
            else
            {
                result = e;
                result.type = e.e2.type;
            }
        }

        override void visit(SliceExp e)
        {
            //printf("SliceExp::castTo e = %s, type = %s, t = %s\n", e.toChars(), e.type.toChars(), t.toChars());

            Type tb = t.toBasetype();
            Type typeb = e.type.toBasetype();

            if (e.type.equals(t) || typeb.ty != Tarray ||
                (tb.ty != Tarray && tb.ty != Tsarray))
            {
                visit(cast(Expression)e);
                return;
            }

            if (tb.ty == Tarray)
            {
                if (typeb.nextOf().equivalent(tb.nextOf()))
                {
                    // T[] to const(T)[]
                    result = e.copy();
                    result.type = t;
                }
                else
                {
                    visit(cast(Expression)e);
                }
                return;
            }

            // Handle the cast from Tarray to Tsarray with CT-known slicing

            TypeSArray tsa = toStaticArrayType(e).isTypeSArray();
            if (tsa && tsa.size(e.loc) == tb.size(e.loc))
            {
                /* Match if the sarray sizes are equal:
                 *  T[a .. b] to const(T)[b-a]
                 *  T[a .. b] to U[dim] if (T.sizeof*(b-a) == U.sizeof*dim)
                 *
                 * If a SliceExp has Tsarray, it will become lvalue.
                 * That's handled in SliceExp::isLvalue and toLvalue
                 */
                result = e.copy();
                result.type = t;
                return;
            }
            if (tsa && tsa.dim.equals(tb.isTypeSArray().dim))
            {
                /* Match if the dimensions are equal
                 * with the implicit conversion of e.e1:
                 *  cast(float[2]) [2.0, 1.0, 0.0][0..2];
                 */
                Type t1b = e.e1.type.toBasetype();
                if (t1b.ty == Tsarray)
                    t1b = tb.nextOf().sarrayOf(t1b.isTypeSArray().dim.toInteger());
                else if (t1b.ty == Tarray)
                    t1b = tb.nextOf().arrayOf();
                else if (t1b.ty == Tpointer)
                    t1b = tb.nextOf().pointerTo();
                else
                    assert(0);
                if (e.e1.implicitConvTo(t1b) > MATCH.nomatch)
                {
                    Expression e1x = e.e1.implicitCastTo(sc, t1b);
                    assert(e1x.op != TOK.error);
                    e = cast(SliceExp)e.copy();
                    e.e1 = e1x;
                    e.type = t;
                    result = e;
                    return;
                }
            }
            auto ts = toAutoQualChars(tsa ? tsa : e.type, t);
            e.error("cannot cast expression `%s` of type `%s` to `%s`",
                e.toChars(), ts[0], ts[1]);
            result = ErrorExp.get();
        }
    }

    // Casting to noreturn isn't an actual cast
    // Rewrite cast(<qual> noreturn) <exp>
    // as      <exp>, assert(false)
    if (t.isTypeNoreturn())
    {
        // Don't generate an unreachable assert(false) if e will abort
        if (e.type.isTypeNoreturn())
        {
            // Paint e to accomodate for different type qualifiers
            e.type = t;
            return e;
        }

        auto ini = t.defaultInitLiteral(e.loc);
        return Expression.combine(e, ini);
    }

    scope CastTo v = new CastTo(sc, t);
    e.accept(v);
    return v.result;
}

/****************************************
 * Set type inference target
 *      t       Target type
 *      flag    1: don't put an error when inference fails
 */
Expression inferType(Expression e, Type t, int flag = 0)
{
    Expression visitAle(ArrayLiteralExp ale)
    {
        Type tb = t.toBasetype();
        if (tb.ty == Tarray || tb.ty == Tsarray)
        {
            Type tn = tb.nextOf();
            if (ale.basis)
                ale.basis = inferType(ale.basis, tn, flag);
            for (size_t i = 0; i < ale.elements.dim; i++)
            {
                if (Expression e = (*ale.elements)[i])
                {
                    e = inferType(e, tn, flag);
                    (*ale.elements)[i] = e;
                }
            }
        }
        return ale;
    }

    Expression visitAar(AssocArrayLiteralExp aale)
    {
        Type tb = t.toBasetype();
        if (auto taa = tb.isTypeAArray())
        {
            Type ti = taa.index;
            Type tv = taa.nextOf();
            for (size_t i = 0; i < aale.keys.dim; i++)
            {
                if (Expression e = (*aale.keys)[i])
                {
                    e = inferType(e, ti, flag);
                    (*aale.keys)[i] = e;
                }
            }
            for (size_t i = 0; i < aale.values.dim; i++)
            {
                if (Expression e = (*aale.values)[i])
                {
                    e = inferType(e, tv, flag);
                    (*aale.values)[i] = e;
                }
            }
        }
        return aale;
    }

    Expression visitFun(FuncExp fe)
    {
        //printf("FuncExp::inferType('%s'), to=%s\n", fe.type ? fe.type.toChars() : "null", t.toChars());
        if (t.ty == Tdelegate || t.ty == Tpointer && t.nextOf().ty == Tfunction)
        {
            fe.fd.treq = t;
        }
        return fe;
    }

    Expression visitTer(CondExp ce)
    {
        Type tb = t.toBasetype();
        ce.e1 = inferType(ce.e1, tb, flag);
        ce.e2 = inferType(ce.e2, tb, flag);
        return ce;
    }

    if (t) switch (e.op)
    {
        case TOK.arrayLiteral:      return visitAle(cast(ArrayLiteralExp) e);
        case TOK.assocArrayLiteral: return visitAar(cast(AssocArrayLiteralExp) e);
        case TOK.function_:         return visitFun(cast(FuncExp) e);
        case TOK.question:          return visitTer(cast(CondExp) e);
        default:
    }
    return e;
}

/****************************************
 * Scale addition/subtraction to/from pointer.
 */
Expression scaleFactor(BinExp be, Scope* sc)
{
    Type t1b = be.e1.type.toBasetype();
    Type t2b = be.e2.type.toBasetype();
    Expression eoff;

    if (t1b.ty == Tpointer && t2b.isintegral())
    {
        // Need to adjust operator by the stride
        // Replace (ptr + int) with (ptr + (int * stride))
        Type t = Type.tptrdiff_t;

        d_uns64 stride = t1b.nextOf().size(be.loc);
        if (!t.equals(t2b))
            be.e2 = be.e2.castTo(sc, t);
        eoff = be.e2;
        be.e2 = new MulExp(be.loc, be.e2, new IntegerExp(Loc.initial, stride, t));
        be.e2.type = t;
        be.type = be.e1.type;
    }
    else if (t2b.ty == Tpointer && t1b.isintegral())
    {
        // Need to adjust operator by the stride
        // Replace (int + ptr) with (ptr + (int * stride))
        Type t = Type.tptrdiff_t;
        Expression e;

        d_uns64 stride = t2b.nextOf().size(be.loc);
        if (!t.equals(t1b))
            e = be.e1.castTo(sc, t);
        else
            e = be.e1;
        eoff = e;
        e = new MulExp(be.loc, e, new IntegerExp(Loc.initial, stride, t));
        e.type = t;
        be.type = be.e2.type;
        be.e1 = be.e2;
        be.e2 = e;
    }
    else
        assert(0);

    if (sc.func && !sc.intypeof)
    {
        eoff = eoff.optimize(WANTvalue);
        if (eoff.op == TOK.int64 && eoff.toInteger() == 0)
        {
        }
        else if (sc.func.setUnsafe())
        {
            be.error("pointer arithmetic not allowed in @safe functions");
            return ErrorExp.get();
        }
    }

    return be;
}

/**************************************
 * Return true if e is an empty array literal with dimensionality
 * equal to or less than type of other array.
 * [], [[]], [[[]]], etc.
 * I.e., make sure that [1,2] is compatible with [],
 * [[1,2]] is compatible with [[]], etc.
 */
private bool isVoidArrayLiteral(Expression e, Type other)
{
    while (e.op == TOK.arrayLiteral && e.type.ty == Tarray && ((cast(ArrayLiteralExp)e).elements.dim == 1))
    {
        auto ale = cast(ArrayLiteralExp)e;
        e = ale[0];
        if (other.ty == Tsarray || other.ty == Tarray)
            other = other.nextOf();
        else
            return false;
    }
    if (other.ty != Tsarray && other.ty != Tarray)
        return false;
    Type t = e.type;
    return (e.op == TOK.arrayLiteral && t.ty == Tarray && t.nextOf().ty == Tvoid && (cast(ArrayLiteralExp)e).elements.dim == 0);
}

/**
 * Merge types of `e1` and `e2` into a common subset
 *
 * Parameters `e1` and `e2` will be rewritten in place as needed.
 *
 * Params:
 *     sc  = Current scope
 *     op  = Operator such as `e1 op e2`. In practice, either TOK.question
 *           or one of the binary operator.
 *     pe1 = The LHS of the operation, will be rewritten
 *     pe2 = The RHS of the operation, will be rewritten
 *
 * Returns:
 *      The resulting type in case of success, `null` in case of error
 */
Type typeMerge(Scope* sc, TOK op, ref Expression pe1, ref Expression pe2)
{
    //printf("typeMerge() %s op %s\n", e1.toChars(), e2.toChars());

    Expression e1 = pe1;
    Expression e2 = pe2;

    // ImportC: do array/function conversions
    if (sc)
    {
        e1 = e1.arrayFuncConv(sc);
        e2 = e2.arrayFuncConv(sc);
    }

    Type Lret(Type result)
    {
        pe1 = e1;
        pe2 = e2;

        version (none)
        {
            printf("-typeMerge() %s op %s\n", e1.toChars(), e2.toChars());
            if (e1.type)
                printf("\tt1 = %s\n", e1.type.toChars());
            if (e2.type)
                printf("\tt2 = %s\n", e2.type.toChars());
            printf("\ttype = %s\n", result.toChars());
        }
        return result;
    }

    /// Converts one of the expression to the other
    Type convert(ref Expression from, Type to)
    {
        from = from.castTo(sc, to);
        return Lret(to);
    }

    /// Converts both expression to a third type
    Type coerce(Type towards)
    {
        e1 = e1.castTo(sc, towards);
        e2 = e2.castTo(sc, towards);
        return Lret(towards);
    }

    Type t1b = e1.type.toBasetype();
    Type t2b = e2.type.toBasetype();

    if (sc && sc.flags & SCOPE.Cfile)
    {
        // Integral types can be implicitly converted to pointers
        if ((t1b.ty == Tpointer) != (t2b.ty == Tpointer))
        {
            if (t1b.isintegral())
            {
                return convert(e1, t2b);
            }
            else if (t2b.isintegral())
            {
                return convert(e2, t1b);
            }
        }
    }

    if (op != TOK.question || t1b.ty != t2b.ty && (t1b.isTypeBasic() && t2b.isTypeBasic()))
    {
        if (op == TOK.question && t1b.ty.isSomeChar() && t2b.ty.isSomeChar())
        {
            e1 = e1.castTo(sc, Type.tdchar);
            e2 = e2.castTo(sc, Type.tdchar);
        }
        else
        {
            e1 = integralPromotions(e1, sc);
            e2 = integralPromotions(e2, sc);
        }
    }

    MATCH m;
    Type t1 = e1.type;
    Type t2 = e2.type;
    assert(t1);
    Type t = t1;

    /* The start type of alias this type recursion.
     * In following case, we should save A, and stop recursion
     * if it appears again.
     *      X -> Y -> [A] -> B -> A -> B -> ...
     */
    Type att1 = null;
    Type att2 = null;

    if (t1.mod != t2.mod &&
        t1.ty == Tenum && t2.ty == Tenum &&
        t1.isTypeEnum().sym == t2.isTypeEnum().sym)
    {
        ubyte mod = MODmerge(t1.mod, t2.mod);
        t1 = t1.castMod(mod);
        t2 = t2.castMod(mod);
    }

Lagain:
    t1b = t1.toBasetype();
    t2b = t2.toBasetype();

    const ty = implicitConvCommonTy(t1b.ty, t2b.ty);
    if (ty != Terror)
    {
        const ty1 = implicitConvTy1(t1b.ty, t2b.ty);
        const ty2 = implicitConvTy1(t2b.ty, t1b.ty);

        if (t1b.ty == ty1) // if no promotions
        {
            if (t1.equals(t2))
                return Lret(t1);

            if (t1b.equals(t2b))
                return Lret(t1b);
        }

        t1 = Type.basic[ty1];
        t2 = Type.basic[ty2];
        e1 = e1.castTo(sc, t1);
        e2 = e2.castTo(sc, t2);
        return Lret(Type.basic[ty]);
    }

    t1 = t1b;
    t2 = t2b;

    if (t1.ty == Ttuple || t2.ty == Ttuple)
        return null;

    if (t1.equals(t2))
    {
        // merging can not result in new enum type
        if (t.ty == Tenum)
            return Lret(t1b);
        return Lret(t);
    }

    if ((t1.ty == Tpointer && t2.ty == Tpointer) || (t1.ty == Tdelegate && t2.ty == Tdelegate))
    {
        // Bring pointers to compatible type
        Type t1n = t1.nextOf();
        Type t2n = t2.nextOf();

        if (t1n.equals(t2n))
            return Lret(t);

        if (t1n.ty == Tvoid) // pointers to void are always compatible
            return Lret(t2);

        if (t2n.ty == Tvoid)
            return Lret(t);

        if (t1.implicitConvTo(t2))
            return convert(e1, t2);

        if (t2.implicitConvTo(t1))
            return convert(e2, t1);

        if (t1n.ty == Tfunction && t2n.ty == Tfunction)
        {
            TypeFunction tf1 = t1n.isTypeFunction();
            TypeFunction tf2 = t2n.isTypeFunction();
            tf1.purityLevel();
            tf2.purityLevel();

            TypeFunction d = tf1.syntaxCopy();

            if (tf1.purity != tf2.purity)
                d.purity = PURE.impure;
            assert(d.purity != PURE.fwdref);

            d.isnothrow = (tf1.isnothrow && tf2.isnothrow);
            d.isnogc = (tf1.isnogc && tf2.isnogc);

            if (tf1.trust == tf2.trust)
                d.trust = tf1.trust;
            else if (tf1.trust <= TRUST.system || tf2.trust <= TRUST.system)
                d.trust = TRUST.system;
            else
                d.trust = TRUST.trusted;

            Type tx = (t1.ty == Tdelegate) ? new TypeDelegate(d) : d.pointerTo();
            tx = tx.typeSemantic(e1.loc, sc);

            if (t1.implicitConvTo(tx) && t2.implicitConvTo(tx))
                return coerce(tx);
            return null;
        }

        if (t1n.mod != t2n.mod)
        {
            if (!t1n.isImmutable() && !t2n.isImmutable() && t1n.isShared() != t2n.isShared())
                return null;
            ubyte mod = MODmerge(t1n.mod, t2n.mod);
            t1 = t1n.castMod(mod).pointerTo();
            t2 = t2n.castMod(mod).pointerTo();
            t = t1;
            goto Lagain;
        }

        if (t1n.ty == Tclass && t2n.ty == Tclass)
        {
            ClassDeclaration cd1 = t1n.isClassHandle();
            ClassDeclaration cd2 = t2n.isClassHandle();
            int offset;
            if (cd1.isBaseOf(cd2, &offset))
            {
                if (offset)
                    e2 = e2.castTo(sc, t);
                return Lret(t);
            }

            if (cd2.isBaseOf(cd1, &offset))
            {
                if (offset)
                    e1 = e1.castTo(sc, t2);
                return Lret(t2);
            }

            return null;
        }

        t1 = t1n.constOf().pointerTo();
        t2 = t2n.constOf().pointerTo();
        if (t1.implicitConvTo(t2))
            return convert(e1, t2);
        if (t2.implicitConvTo(t1))
            return convert(e2, t1);
        return null;
    }

    if ((t1.ty == Tsarray || t1.ty == Tarray) && (e2.op == TOK.null_ && t2.ty == Tpointer && t2.nextOf().ty == Tvoid || e2.op == TOK.arrayLiteral && t2.ty == Tsarray && t2.nextOf().ty == Tvoid && t2.isTypeSArray().dim.toInteger() == 0 || isVoidArrayLiteral(e2, t1)))
    {
        /*  (T[n] op void*)   => T[]
         *  (T[]  op void*)   => T[]
         *  (T[n] op void[0]) => T[]
         *  (T[]  op void[0]) => T[]
         *  (T[n] op void[])  => T[]
         *  (T[]  op void[])  => T[]
         */
        return coerce(t1.nextOf().arrayOf());
    }

    if ((t2.ty == Tsarray || t2.ty == Tarray) && (e1.op == TOK.null_ && t1.ty == Tpointer && t1.nextOf().ty == Tvoid || e1.op == TOK.arrayLiteral && t1.ty == Tsarray && t1.nextOf().ty == Tvoid && t1.isTypeSArray().dim.toInteger() == 0 || isVoidArrayLiteral(e1, t2)))
    {
        /*  (void*   op T[n]) => T[]
         *  (void*   op T[])  => T[]
         *  (void[0] op T[n]) => T[]
         *  (void[0] op T[])  => T[]
         *  (void[]  op T[n]) => T[]
         *  (void[]  op T[])  => T[]
         */
        return coerce(t2.nextOf().arrayOf());
    }

    if ((t1.ty == Tsarray || t1.ty == Tarray) && (m = t1.implicitConvTo(t2)) != MATCH.nomatch)
    {
        // https://issues.dlang.org/show_bug.cgi?id=7285
        // Tsarray op [x, y, ...] should to be Tsarray
        // https://issues.dlang.org/show_bug.cgi?id=14737
        // Tsarray ~ [x, y, ...] should to be Tarray
        if (t1.ty == Tsarray && e2.op == TOK.arrayLiteral && op != TOK.concatenate)
            return convert(e2, t1);
        if (m == MATCH.constant && (op == TOK.addAssign || op == TOK.minAssign || op == TOK.mulAssign || op == TOK.divAssign || op == TOK.modAssign || op == TOK.powAssign || op == TOK.andAssign || op == TOK.orAssign || op == TOK.xorAssign))
        {
            // Don't make the lvalue const
            return Lret(t2);
        }
        return convert(e1, t2);
    }

    if ((t2.ty == Tsarray || t2.ty == Tarray) && t2.implicitConvTo(t1))
    {
        // https://issues.dlang.org/show_bug.cgi?id=7285
        // https://issues.dlang.org/show_bug.cgi?id=14737
        if (t2.ty == Tsarray && e1.op == TOK.arrayLiteral && op != TOK.concatenate)
            return convert(e1, t2);
        return convert(e2, t1);
    }

    if ((t1.ty == Tsarray || t1.ty == Tarray || t1.ty == Tpointer) && (t2.ty == Tsarray || t2.ty == Tarray || t2.ty == Tpointer) && t1.nextOf().mod != t2.nextOf().mod)
    {
        /* If one is mutable and the other immutable, then retry
         * with both of them as const
         */
        Type t1n = t1.nextOf();
        Type t2n = t2.nextOf();
        ubyte mod;
        if (e1.op == TOK.null_ && e2.op != TOK.null_)
            mod = t2n.mod;
        else if (e1.op != TOK.null_ && e2.op == TOK.null_)
            mod = t1n.mod;
        else if (!t1n.isImmutable() && !t2n.isImmutable() && t1n.isShared() != t2n.isShared())
            return null;
        else
            mod = MODmerge(t1n.mod, t2n.mod);

        if (t1.ty == Tpointer)
            t1 = t1n.castMod(mod).pointerTo();
        else
            t1 = t1n.castMod(mod).arrayOf();

        if (t2.ty == Tpointer)
            t2 = t2n.castMod(mod).pointerTo();
        else
            t2 = t2n.castMod(mod).arrayOf();
        t = t1;
        goto Lagain;
    }

    if (t1.ty == Tclass && t2.ty == Tclass)
    {
        if (t1.mod != t2.mod)
        {
            ubyte mod;
            if (e1.op == TOK.null_ && e2.op != TOK.null_)
                mod = t2.mod;
            else if (e1.op != TOK.null_ && e2.op == TOK.null_)
                mod = t1.mod;
            else if (!t1.isImmutable() && !t2.isImmutable() && t1.isShared() != t2.isShared())
                return null;
            else
                mod = MODmerge(t1.mod, t2.mod);
            t1 = t1.castMod(mod);
            t2 = t2.castMod(mod);
            t = t1;
            goto Lagain;
        }
        goto Lcc;
    }

    if (t1.ty == Tclass || t2.ty == Tclass)
    {
    Lcc:
        while (1)
        {
            MATCH i1 = e2.implicitConvTo(t1);
            MATCH i2 = e1.implicitConvTo(t2);

            if (i1 && i2)
            {
                // We have the case of class vs. void*, so pick class
                if (t1.ty == Tpointer)
                    i1 = MATCH.nomatch;
                else if (t2.ty == Tpointer)
                    i2 = MATCH.nomatch;
            }

            if (i2)
                return coerce(t2);
            if (i1)
                return coerce(t1);

            if (t1.ty == Tclass && t2.ty == Tclass)
            {
                TypeClass tc1 = t1.isTypeClass();
                TypeClass tc2 = t2.isTypeClass();

                /* Pick 'tightest' type
                 */
                ClassDeclaration cd1 = tc1.sym.baseClass;
                ClassDeclaration cd2 = tc2.sym.baseClass;
                if (cd1 && cd2)
                {
                    t1 = cd1.type.castMod(t1.mod);
                    t2 = cd2.type.castMod(t2.mod);
                }
                else if (cd1)
                    t1 = cd1.type;
                else if (cd2)
                    t2 = cd2.type;
                else
                    return null;
            }
            else if (t1.ty == Tstruct && t1.isTypeStruct().sym.aliasthis)
            {
                if (isRecursiveAliasThis(att1, e1.type))
                    return null;
                //printf("att tmerge(c || c) e1 = %s\n", e1.type.toChars());
                e1 = resolveAliasThis(sc, e1);
                t1 = e1.type;
                continue;
            }
            else if (t2.ty == Tstruct && t2.isTypeStruct().sym.aliasthis)
            {
                if (isRecursiveAliasThis(att2, e2.type))
                    return null;
                //printf("att tmerge(c || c) e2 = %s\n", e2.type.toChars());
                e2 = resolveAliasThis(sc, e2);
                t2 = e2.type;
                continue;
            }
            else
                return null;
        }
    }

    if (t1.ty == Tstruct && t2.ty == Tstruct)
    {
        if (t1.mod != t2.mod)
        {
            if (!t1.isImmutable() && !t2.isImmutable() && t1.isShared() != t2.isShared())
                return null;
            ubyte mod = MODmerge(t1.mod, t2.mod);
            t1 = t1.castMod(mod);
            t2 = t2.castMod(mod);
            t = t1;
            goto Lagain;
        }

        TypeStruct ts1 = t1.isTypeStruct();
        TypeStruct ts2 = t2.isTypeStruct();
        if (ts1.sym != ts2.sym)
        {
            if (!ts1.sym.aliasthis && !ts2.sym.aliasthis)
                return null;

            MATCH i1 = MATCH.nomatch;
            MATCH i2 = MATCH.nomatch;

            Expression e1b = null;
            Expression e2b = null;
            if (ts2.sym.aliasthis)
            {
                if (isRecursiveAliasThis(att2, e2.type))
                    return null;
                //printf("att tmerge(s && s) e2 = %s\n", e2.type.toChars());
                e2b = resolveAliasThis(sc, e2);
                i1 = e2b.implicitConvTo(t1);
            }
            if (ts1.sym.aliasthis)
            {
                if (isRecursiveAliasThis(att1, e1.type))
                    return null;
                //printf("att tmerge(s && s) e1 = %s\n", e1.type.toChars());
                e1b = resolveAliasThis(sc, e1);
                i2 = e1b.implicitConvTo(t2);
            }
            if (i1 && i2)
                return null;

            if (i1)
                return convert(e2, t1);
            if (i2)
                return convert(e1, t2);

            if (e1b)
            {
                e1 = e1b;
                t1 = e1b.type.toBasetype();
            }
            if (e2b)
            {
                e2 = e2b;
                t2 = e2b.type.toBasetype();
            }
            t = t1;
            goto Lagain;
        }
    }

    if (t1.ty == Tstruct || t2.ty == Tstruct)
    {
        if (t1.ty == Tstruct && t1.isTypeStruct().sym.aliasthis)
        {
            if (isRecursiveAliasThis(att1, e1.type))
                return null;
            //printf("att tmerge(s || s) e1 = %s\n", e1.type.toChars());
            e1 = resolveAliasThis(sc, e1);
            t1 = e1.type;
            t = t1;
            goto Lagain;
        }
        if (t2.ty == Tstruct && t2.isTypeStruct().sym.aliasthis)
        {
            if (isRecursiveAliasThis(att2, e2.type))
                return null;
            //printf("att tmerge(s || s) e2 = %s\n", e2.type.toChars());
            e2 = resolveAliasThis(sc, e2);
            t2 = e2.type;
            t = t2;
            goto Lagain;
        }
        return null;
    }

    if ((e1.op == TOK.string_ || e1.op == TOK.null_) && e1.implicitConvTo(t2))
        return convert(e1, t2);
    if ((e2.op == TOK.string_ || e2.op == TOK.null_) && e2.implicitConvTo(t1))
        return convert(e2, t1);
    if (t1.ty == Tsarray && t2.ty == Tsarray && e2.implicitConvTo(t1.nextOf().arrayOf()))
        return coerce(t1.nextOf().arrayOf());
    if (t1.ty == Tsarray && t2.ty == Tsarray && e1.implicitConvTo(t2.nextOf().arrayOf()))
        return coerce(t2.nextOf().arrayOf());

    if (t1.ty == Tvector && t2.ty == Tvector)
    {
        // https://issues.dlang.org/show_bug.cgi?id=13841
        // all vector types should have no common types between
        // different vectors, even though their sizes are same.
        auto tv1 = t1.isTypeVector();
        auto tv2 = t2.isTypeVector();
        if (!tv1.basetype.equals(tv2.basetype))
            return null;

        goto LmodCompare;
    }

    if (t1.ty == Tvector && t2.ty != Tvector && e2.implicitConvTo(t1))
    {
        e2 = e2.castTo(sc, t1);
        t2 = t1;
        t = t1;
        goto Lagain;
    }

    if (t2.ty == Tvector && t1.ty != Tvector && e1.implicitConvTo(t2))
    {
        e1 = e1.castTo(sc, t2);
        t1 = t2;
        t = t1;
        goto Lagain;
    }

    if (t1.isintegral() && t2.isintegral())
    {
        if (t1.ty != t2.ty)
        {
            if (t1.ty == Tvector || t2.ty == Tvector)
                return null;
            e1 = integralPromotions(e1, sc);
            e2 = integralPromotions(e2, sc);
            t1 = e1.type;
            t2 = e2.type;
            goto Lagain;
        }
        assert(t1.ty == t2.ty);
LmodCompare:
        if (!t1.isImmutable() && !t2.isImmutable() && t1.isShared() != t2.isShared())
            return null;
        ubyte mod = MODmerge(t1.mod, t2.mod);

        t1 = t1.castMod(mod);
        t2 = t2.castMod(mod);
        t = t1;
        e1 = e1.castTo(sc, t);
        e2 = e2.castTo(sc, t);
        goto Lagain;
    }

    if (t1.ty == Tnull && t2.ty == Tnull)
    {
        ubyte mod = MODmerge(t1.mod, t2.mod);
        return coerce(t1.castMod(mod));
    }

    if (t2.ty == Tnull && (t1.ty == Tpointer || t1.ty == Taarray || t1.ty == Tarray))
        return convert(e2, t1);
    if (t1.ty == Tnull && (t2.ty == Tpointer || t2.ty == Taarray || t2.ty == Tarray))
        return convert(e1, t2);

    if (t1.ty == Tarray && isBinArrayOp(op) && isArrayOpOperand(e1))
    {
        if (e2.implicitConvTo(t1.nextOf()))
        {
            // T[] op T
            // T[] op cast(T)U
            e2 = e2.castTo(sc, t1.nextOf());
            return Lret(t1.nextOf().arrayOf());
        }
        if (t1.nextOf().implicitConvTo(e2.type))
        {
            // (cast(T)U)[] op T    (https://issues.dlang.org/show_bug.cgi?id=12780)
            // e1 is left as U[], it will be handled in arrayOp() later.
            return Lret(e2.type.arrayOf());
        }
        if (t2.ty == Tarray && isArrayOpOperand(e2))
        {
            if (t1.nextOf().implicitConvTo(t2.nextOf()))
            {
                // (cast(T)U)[] op T[]  (https://issues.dlang.org/show_bug.cgi?id=12780)
                t = t2.nextOf().arrayOf();
                // if cast won't be handled in arrayOp() later
                if (!isArrayOpImplicitCast(t1.isTypeDArray(), t2.isTypeDArray()))
                    e1 = e1.castTo(sc, t);
                return Lret(t);
            }
            if (t2.nextOf().implicitConvTo(t1.nextOf()))
            {
                // T[] op (cast(T)U)[]  (https://issues.dlang.org/show_bug.cgi?id=12780)
                // e2 is left as U[], it will be handled in arrayOp() later.
                t = t1.nextOf().arrayOf();
                // if cast won't be handled in arrayOp() later
                if (!isArrayOpImplicitCast(t2.isTypeDArray(), t1.isTypeDArray()))
                    e2 = e2.castTo(sc, t);
                return Lret(t);
            }
            return null;
        }
        return null;
    }
    else if (t2.ty == Tarray && isBinArrayOp(op) && isArrayOpOperand(e2))
    {
        if (e1.implicitConvTo(t2.nextOf()))
        {
            // T op T[]
            // cast(T)U op T[]
            e1 = e1.castTo(sc, t2.nextOf());
            t = t2.nextOf().arrayOf();
        }
        else if (t2.nextOf().implicitConvTo(e1.type))
        {
            // T op (cast(T)U)[]    (https://issues.dlang.org/show_bug.cgi?id=12780)
            // e2 is left as U[], it will be handled in arrayOp() later.
            t = e1.type.arrayOf();
        }
        else
            return null;

        //printf("test %s\n", Token::toChars(op));
        e1 = e1.optimize(WANTvalue);
        if (isCommutative(op) && e1.isConst())
        {
            /* Swap operands to minimize number of functions generated
             */
            //printf("swap %s\n", Token::toChars(op));
            Expression tmp = e1;
            e1 = e2;
            e2 = tmp;
        }
        return Lret(t);
    }

    return null;
}

/************************************
 * Bring leaves to common type.
 * Returns:
 *    null on success, ErrorExp if error occurs
 */
Expression typeCombine(BinExp be, Scope* sc)
{
    Expression errorReturn()
    {
        Expression ex = be.incompatibleTypes();
        if (ex.op == TOK.error)
            return ex;
        return ErrorExp.get();
    }

    Type t1 = be.e1.type.toBasetype();
    Type t2 = be.e2.type.toBasetype();

    if (be.op == TOK.min || be.op == TOK.add)
    {
        // struct+struct, and class+class are errors
        if (t1.ty == Tstruct && t2.ty == Tstruct)
            return errorReturn();
        else if (t1.ty == Tclass && t2.ty == Tclass)
            return errorReturn();
        else if (t1.ty == Taarray && t2.ty == Taarray)
            return errorReturn();
    }

    if (auto result = typeMerge(sc, be.op, be.e1, be.e2))
    {
        if (be.type is null)
            be.type = result;
    }
    else
        return errorReturn();

    // If the types have no value, return an error
    if (be.e1.op == TOK.error)
        return be.e1;
    if (be.e2.op == TOK.error)
        return be.e2;
    return null;
}

/***********************************
 * Do integral promotions (convertchk).
 * Don't convert <array of> to <pointer to>
 */
Expression integralPromotions(Expression e, Scope* sc)
{
    //printf("integralPromotions %s %s\n", e.toChars(), e.type.toChars());
    switch (e.type.toBasetype().ty)
    {
    case Tvoid:
        e.error("void has no value");
        return ErrorExp.get();

    case Tint8:
    case Tuns8:
    case Tint16:
    case Tuns16:
    case Tbool:
    case Tchar:
    case Twchar:
        e = e.castTo(sc, Type.tint32);
        break;

    case Tdchar:
        e = e.castTo(sc, Type.tuns32);
        break;

    default:
        break;
    }
    return e;
}

/******************************************************
 * This provides a transition from the non-promoting behavior
 * of unary + - ~ to the C-like integral promotion behavior.
 * Params:
 *    sc = context
 *    ue = NegExp, UAddExp, or ComExp which is revised per rules
 * References:
 *      https://issues.dlang.org/show_bug.cgi?id=16997
 */

void fix16997(Scope* sc, UnaExp ue)
{
    if (global.params.fix16997 || sc.flags & SCOPE.Cfile)
        ue.e1 = integralPromotions(ue.e1, sc);          // desired C-like behavor
    else
    {
        switch (ue.e1.type.toBasetype.ty)
        {
            case Tint8:
            case Tuns8:
            case Tint16:
            case Tuns16:
            //case Tbool:       // these operations aren't allowed on bool anyway
            case Tchar:
            case Twchar:
            case Tdchar:
                ue.deprecation("integral promotion not done for `%s`, use '-preview=intpromote' switch or `%scast(int)(%s)`",
                    ue.toChars(), Token.toChars(ue.op), ue.e1.toChars());
                break;

            default:
                break;
        }
    }
}

/***********************************
 * See if both types are arrays that can be compared
 * for equality without any casting. Return true if so.
 * This is to enable comparing things like an immutable
 * array with a mutable one.
 */
extern (C++) bool arrayTypeCompatibleWithoutCasting(Type t1, Type t2)
{
    t1 = t1.toBasetype();
    t2 = t2.toBasetype();

    if ((t1.ty == Tarray || t1.ty == Tsarray || t1.ty == Tpointer) && t2.ty == t1.ty)
    {
        if (t1.nextOf().implicitConvTo(t2.nextOf()) >= MATCH.constant || t2.nextOf().implicitConvTo(t1.nextOf()) >= MATCH.constant)
            return true;
    }
    return false;
}

/******************************************************************/
/* Determine the integral ranges of an expression.
 * This is used to determine if implicit narrowing conversions will
 * be allowed.
 */
IntRange getIntRange(Expression e)
{
    extern (C++) final class IntRangeVisitor : Visitor
    {
        alias visit = Visitor.visit;

    public:
        IntRange range;

        override void visit(Expression e)
        {
            range = IntRange.fromType(e.type);
        }

        override void visit(IntegerExp e)
        {
            range = IntRange(SignExtendedNumber(e.getInteger()))._cast(e.type);
        }

        override void visit(CastExp e)
        {
            range = getIntRange(e.e1)._cast(e.type);
        }

        override void visit(AddExp e)
        {
            IntRange ir1 = getIntRange(e.e1);
            IntRange ir2 = getIntRange(e.e2);
            range = (ir1 + ir2)._cast(e.type);
        }

        override void visit(MinExp e)
        {
            IntRange ir1 = getIntRange(e.e1);
            IntRange ir2 = getIntRange(e.e2);
            range = (ir1 - ir2)._cast(e.type);
        }

        override void visit(DivExp e)
        {
            IntRange ir1 = getIntRange(e.e1);
            IntRange ir2 = getIntRange(e.e2);

            range = (ir1 / ir2)._cast(e.type);
        }

        override void visit(MulExp e)
        {
            IntRange ir1 = getIntRange(e.e1);
            IntRange ir2 = getIntRange(e.e2);

            range = (ir1 * ir2)._cast(e.type);
        }

        override void visit(ModExp e)
        {
            IntRange ir1 = getIntRange(e.e1);
            IntRange ir2 = getIntRange(e.e2);

            // Modding on 0 is invalid anyway.
            if (!ir2.absNeg().imin.negative)
            {
                visit(cast(Expression)e);
                return;
            }
            range = (ir1 % ir2)._cast(e.type);
        }

        override void visit(AndExp e)
        {
            IntRange result;
            bool hasResult = false;
            result.unionOrAssign(getIntRange(e.e1) & getIntRange(e.e2), hasResult);

            assert(hasResult);
            range = result._cast(e.type);
        }

        override void visit(OrExp e)
        {
            IntRange result;
            bool hasResult = false;
            result.unionOrAssign(getIntRange(e.e1) | getIntRange(e.e2), hasResult);

            assert(hasResult);
            range = result._cast(e.type);
        }

        override void visit(XorExp e)
        {
            IntRange result;
            bool hasResult = false;
            result.unionOrAssign(getIntRange(e.e1) ^ getIntRange(e.e2), hasResult);

            assert(hasResult);
            range = result._cast(e.type);
        }

        override void visit(ShlExp e)
        {
            IntRange ir1 = getIntRange(e.e1);
            IntRange ir2 = getIntRange(e.e2);

            range = (ir1 << ir2)._cast(e.type);
        }

        override void visit(ShrExp e)
        {
            IntRange ir1 = getIntRange(e.e1);
            IntRange ir2 = getIntRange(e.e2);

            range = (ir1 >> ir2)._cast(e.type);
        }

        override void visit(UshrExp e)
        {
            IntRange ir1 = getIntRange(e.e1).castUnsigned(e.e1.type);
            IntRange ir2 = getIntRange(e.e2);

            range = (ir1 >>> ir2)._cast(e.type);
        }

        override void visit(AssignExp e)
        {
            range = getIntRange(e.e2)._cast(e.type);
        }

        override void visit(CondExp e)
        {
            // No need to check e.econd; assume caller has called optimize()
            IntRange ir1 = getIntRange(e.e1);
            IntRange ir2 = getIntRange(e.e2);
            range = ir1.unionWith(ir2)._cast(e.type);
        }

        override void visit(VarExp e)
        {
            Expression ie;
            VarDeclaration vd = e.var.isVarDeclaration();
            if (vd && vd.range)
                range = vd.range._cast(e.type);
            else if (vd && vd._init && !vd.type.isMutable() && (ie = vd.getConstInitializer()) !is null)
                ie.accept(this);
            else
                visit(cast(Expression)e);
        }

        override void visit(CommaExp e)
        {
            e.e2.accept(this);
        }

        override void visit(ComExp e)
        {
            IntRange ir = getIntRange(e.e1);
            range = IntRange(SignExtendedNumber(~ir.imax.value, !ir.imax.negative), SignExtendedNumber(~ir.imin.value, !ir.imin.negative))._cast(e.type);
        }

        override void visit(NegExp e)
        {
            IntRange ir = getIntRange(e.e1);
            range = (-ir)._cast(e.type);
        }
    }

    scope IntRangeVisitor v = new IntRangeVisitor();
    e.accept(v);
    return v.range;
}
