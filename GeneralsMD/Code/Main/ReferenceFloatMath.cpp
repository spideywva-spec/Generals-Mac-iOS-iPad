/*
** Command & Conquer Generals: Zero Hour
** Cross-platform float math compatibility for Generals Online.
**
** The 32-bit MSVC PC client evaluates float transcendental functions as a
** double-precision CRT call followed by one conversion back to float. On
** Android, iOS and Unix, native sinf/atan2f/etc. implementations can produce
** different last bits. These values feed the game simulation and can cause
** online CRC mismatches.
**
** Compile without a PCH and with -fno-builtin so clang cannot fold wrappers
** back into calls to sinf/cosf.
*/

#if !(defined(_MSC_VER) && defined(_M_IX86))

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

typedef double (*GXMathFn1)(double);
typedef double (*GXMathFn2)(double, double);

static void *gxRealMathSymbol(const char *name)
{
    void *symbol = dlsym(RTLD_NEXT, name);
    if (symbol != nullptr)
        return symbol;

#if defined(__APPLE__)
    void *libm = dlopen("/usr/lib/libSystem.B.dylib", RTLD_NOW);
#elif defined(__ANDROID__)
    void *libm = dlopen("libm.so", RTLD_NOW);
#else
    void *libm = dlopen("libm.so.6", RTLD_NOW);
    if (libm == nullptr)
        libm = dlopen("libm.so", RTLD_NOW);
#endif
    if (libm != nullptr)
        symbol = dlsym(libm, name);

    if (symbol == nullptr)
    {
        fprintf(stderr, "[ONLINE-MATH-COMPAT] Could not resolve system math function %s\\n", name);
        abort();
    }
    return symbol;
}

#define GX_REF_MATH extern "C" __attribute__((visibility("hidden")))
#define GX_FORWARD_MATH1(name) \\
    GX_REF_MATH double name(double x) \\
    { \\
        static GXMathFn1 realFunction = reinterpret_cast<GXMathFn1>(gxRealMathSymbol(#name)); \\
        return realFunction(x); \\
    }

GX_FORWARD_MATH1(sin)
GX_FORWARD_MATH1(cos)
GX_FORWARD_MATH1(tan)
GX_FORWARD_MATH1(asin)
GX_FORWARD_MATH1(acos)
GX_FORWARD_MATH1(atan)
GX_FORWARD_MATH1(sinh)
GX_FORWARD_MATH1(cosh)
GX_FORWARD_MATH1(tanh)
GX_FORWARD_MATH1(exp)
GX_FORWARD_MATH1(log)
GX_FORWARD_MATH1(log10)

GX_REF_MATH double atan2(double y, double x)
{
    static GXMathFn2 realFunction = reinterpret_cast<GXMathFn2>(gxRealMathSymbol("atan2"));
    return realFunction(y, x);
}

GX_REF_MATH double pow(double x, double y)
{
    static GXMathFn2 realFunction = reinterpret_cast<GXMathFn2>(gxRealMathSymbol("pow"));
    return realFunction(x, y);
}

GX_REF_MATH float sinf(float x)             { return static_cast<float>(sin(static_cast<double>(x))); }
GX_REF_MATH float cosf(float x)             { return static_cast<float>(cos(static_cast<double>(x))); }
GX_REF_MATH float tanf(float x)             { return static_cast<float>(tan(static_cast<double>(x))); }
GX_REF_MATH float asinf(float x)            { return static_cast<float>(asin(static_cast<double>(x))); }
GX_REF_MATH float acosf(float x)            { return static_cast<float>(acos(static_cast<double>(x))); }
GX_REF_MATH float atanf(float x)            { return static_cast<float>(atan(static_cast<double>(x))); }
GX_REF_MATH float atan2f(float y, float x)  { return static_cast<float>(atan2(static_cast<double>(y), static_cast<double>(x))); }
GX_REF_MATH float sinhf(float x)            { return static_cast<float>(sinh(static_cast<double>(x))); }
GX_REF_MATH float coshf(float x)            { return static_cast<float>(cosh(static_cast<double>(x))); }
GX_REF_MATH float tanhf(float x)            { return static_cast<float>(tanh(static_cast<double>(x))); }
GX_REF_MATH float expf(float x)             { return static_cast<float>(exp(static_cast<double>(x))); }
GX_REF_MATH float logf(float x)             { return static_cast<float>(log(static_cast<double>(x))); }
GX_REF_MATH float log10f(float x)            { return static_cast<float>(log10(static_cast<double>(x))); }
GX_REF_MATH float powf(float x, float y)    { return static_cast<float>(pow(static_cast<double>(x), static_cast<double>(y))); }

GX_REF_MATH void sincos(double x, double *s, double *c)
{
    *s = sin(x);
    *c = cos(x);
}

GX_REF_MATH void sincosf(float x, float *s, float *c)
{
    *s = static_cast<float>(sin(static_cast<double>(x)));
    *c = static_cast<float>(cos(static_cast<double>(x)));
}

__attribute__((constructor)) static void gxReportReferenceFloatMath()
{
    fprintf(stderr, "[ONLINE-MATH-COMPAT] Reference PC float-transcendental semantics enabled\\n");
}

#endif
