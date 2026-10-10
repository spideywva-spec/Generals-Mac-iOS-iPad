#include "string_compat.h"

#include <sstream>
#include <streambuf>
#include <ostream>

char* itoa(int value, char* str, int base)
{
  if (str == nullptr)
    return str;
  if (base < 2 || base > 36)
  {
    str[0] = '\0';
    return str;
  }

  char digits[34];
  int count = 0;
  const bool negative = (base == 10 && value < 0);
  unsigned int magnitude = negative ? 0u - (unsigned int)value : (unsigned int)value;
  do
  {
    const unsigned int digit = magnitude % (unsigned int)base;
    digits[count++] = (char)(digit < 10 ? '0' + digit : 'a' + (digit - 10));
    magnitude /= (unsigned int)base;
  } while (magnitude != 0);

  int out = 0;
  if (negative)
    str[out++] = '-';
  while (count > 0)
    str[out++] = digits[--count];
  str[out] = '\0';
  return str;
}

int _vsnwprintf(wchar_t* buffer, size_t count, const wchar_t* format, va_list args)
{
  std::wstring format_fixup(format);

  // Replace all %s with %ls
  size_t pos = format_fixup.find(L"%s", 0);
  while (pos != std::wstring::npos)
  {
    format_fixup.replace(pos, 2, L"%ls");
    pos += 3;
    pos = format_fixup.find(L"%s", pos);
  }

  // Replace all %S with %s
  pos = format_fixup.find(L"%S", 0);
  while (pos != std::wstring::npos)
  {
    format_fixup.replace(pos, 2, L"%s");
    pos += 2;
    pos = format_fixup.find(L"%S", pos);
  }


  return vswprintf(buffer, count, format_fixup.c_str(), args);
}

// Also defined in GameSpy gsplatformutil
__attribute__((weak))
char* _strlwr(char* str)
{
  for (int i = 0; str[i] != '\0'; i++)
  {
    str[i] = tolower(str[i]);
  }
  return str;
}

// GeneralsX @build fbraz 11/02/2026 BenderAI - Linux portability: uppercase string
__attribute__((weak))
char* _strupr(char* str)
{
  for (int i = 0; str[i] != '\0'; i++)
  {
    str[i] = toupper(str[i]);
  }
  return str;
}