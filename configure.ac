AC_INIT([ccminer-verus-apple], [3.8.3], [], [ccminer], [https://github.com/aelder/ccminer])

AC_PREREQ([2.59c])
AC_CANONICAL_HOST
AC_CONFIG_SRCDIR([ccminer.cpp])
AM_INIT_AUTOMAKE([foreign subdir-objects])
AC_CONFIG_HEADERS([ccminer-config.h])

dnl Make sure anyone changing configure.ac/Makefile.am has a clue
AM_MAINTAINER_MODE

dnl Checks for programs
AC_PROG_CC
AM_PROG_CC_C_O
AM_PROG_AS
AC_PROG_RANLIB
AC_PROG_CXX

dnl Checks for header files
AC_CHECK_HEADERS([sys/endian.h sys/param.h syslog.h])
AC_CHECK_HEADERS([sys/sysctl.h], [], [],
[#include <sys/types.h>
#ifdef HAVE_SYS_PARAM_H
#include <sys/param.h>
#endif
])

AC_CHECK_DECLS([be16dec, le16dec, be16enc, le16enc,
                be32dec, le32dec, be32enc, le32enc], [], [],
[AC_INCLUDES_DEFAULT
#ifdef HAVE_SYS_ENDIAN_H
#include <sys/endian.h>
#endif
])

AC_FUNC_ALLOCA
AC_CHECK_FUNCS([getopt_long])

case $host in
  arm64-apple-darwin*|aarch64-apple-darwin*)
    ;;
  *)
    AC_MSG_ERROR([this tree supports native Apple-silicon macOS only])
    ;;
esac

AC_CHECK_LIB([curl], [curl_easy_init], [], [AC_MSG_ERROR([libcurl required])])
AC_CHECK_LIB([jansson], [json_loads], [], [AC_MSG_ERROR([jansson required])])
AC_CHECK_LIB([z], [gzopen], [], [AC_MSG_ERROR([zlib required])])
AC_CHECK_LIB([ssl],[SSL_free], [], [AC_MSG_ERROR([OpenSSL library required])])
AC_CHECK_LIB([crypto],[EVP_DigestFinal_ex], [], [AC_MSG_ERROR([OpenSSL library required])])

ARCH_FLAGS="-march=armv8-a+fp+simd+crypto -DARM"

AC_SUBST(ARCH_FLAGS)

AC_CONFIG_FILES([
	Makefile
	])

AC_OUTPUT
