/*
**	Command & Conquer Generals Zero Hour(tm)
**	Copyright 2025 Electronic Arts Inc.
**
**	This program is free software: you can redistribute it and/or modify
**	it under the terms of the GNU General Public License as published by
**	the Free Software Foundation, either version 3 of the License, or
**	(at your option) any later version.
**
**	This program is distributed in the hope that it will be useful,
**	but WITHOUT ANY WARRANTY; without even the implied warranty of
**	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
**	GNU General Public License for more details.
**
**	You should have received a copy of the GNU General Public License
**	along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

////////////////////////////////////////////////////////////////////////////////
//																																						//
//  (c) 2001-2003 Electronic Arts Inc.																				//
//																																						//
////////////////////////////////////////////////////////////////////////////////

// Trig.cpp
// fast trig functions
// Author: Michael S. Booth, March 1994
// Converted to Generals by Matthew D. Campbell, February 2002

#include "PreRTS.h"

#include <math.h>
#include <limits.h>

#include "Lib/BaseType.h"
#include "Lib/trig.h"
#include "WWMath/wwmath.h"

#define TWOPI			6.28318530718f
#define DEG2RAD 	0.0174532925199f
#define TRIG_RES 4096

// the following are for fixed point ints with 12 fractional bits
#define INT_ONE								4096
#define INT_TWOPI							25736
#define INT_THREEPIOVERTWO 		19302
#define INT_PI								12868
#define INT_HALFPI 						6434

// Cross-platform lockstep: moving-object orientation matrices are included in the
// simulation CRC. Match the Windows x87/VC6 result by evaluating in double and
// narrowing once on non-MSVC x86 platforms. Keep the original CRT entry points
// on 32-bit MSVC x86, where they provide the Windows compatibility behavior.
Real Sin(Real x)
{
#if defined(_MSC_VER) && defined(_M_IX86)
	return sinf(x);
#else
	return (Real)sin((double)x);
#endif
}

Real Cos(Real x)
{
#if defined(_MSC_VER) && defined(_M_IX86)
	return cosf(x);
#else
	return (Real)cos((double)x);
#endif
}

Real Tan(Real x)
{
#if defined(_MSC_VER) && defined(_M_IX86)
	return tanf(x);
#else
	return (Real)tan((double)x);
#endif
}

Real ACos(Real x)
{
#if defined(_MSC_VER) && defined(_M_IX86)
	return acosf(x);
#else
	return (Real)acos((double)x);
#endif
}

Real ASin(Real x)
{
#if defined(_MSC_VER) && defined(_M_IX86)
	return asinf(x);
#else
	return (Real)asin((double)x);
#endif
}

double Sqrt(double x)
{
	return WWMath::SqrtOrigin(x);
}

#ifdef REGENERATE_TRIG_TABLES
void initTrig()
{
	static Byte inited = FALSE;
	Real angle, r;
	int i;

	if (inited)
		return;

	inited = TRUE;

	static int columns = 8;
	int column = 0;
	FILE *fp = fopen("trig.txt", "w");
	fprintf(fp, "static Int sinLookup[TRIG_RES] = {\n");
	for( i=0; i<TRIG_RES; i++ ) {
		angle = TWOPI * i / (Real)TRIG_RES;
		sinLookup[i] = (Int)(sin(angle) * INT_ONE);

		if (i == 0)
		{
			fprintf(fp, "\t0x%8.8X", sinLookup[i]);
		}
		else if (column == 0)
		{
		fprintf(fp, ",\n\t0x%8.8X", sinLookup[i]);
		}
		else
		{
		fprintf(fp, ", 0x%8.8X", sinLookup[i]);
		}
		column = (column + 1) % columns;
	}
	fprintf(fp, "\n};\n\n");

	column = 0;
	fprintf(fp, "static Int arcCosLookup[2 * INT_ONE] = {\n");
	for( i=0; i<2*INT_ONE; i++ ) {
		r = (Real)i / (Real)INT_ONE - 1.0f;

		arcCosLookup[i] = (Int)(acos( (double)r ) * INT_TWOPI / TWOPI );

		if (i == 0)
		{
			fprintf(fp, "\t0x%8.8X", arcCosLookup[i]);
		}
		else if (column == 0)
		{
		fprintf(fp, ",\n\t0x%8.8X", arcCosLookup[i]);
		}
		else
		{
		fprintf(fp, ", 0x%8.8X", arcCosLookup[i]);
		}
		column = (column + 1) % columns;
	}
	fprintf(fp, "\n};\n\n");

	fclose(fp);
}

class TrigInit
{
public:
	TrigInit() { initTrig(); }
};
TrigInit trigInitializer;

#endif // REGENERATE_TRIG_TABLES


