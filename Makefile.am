EXTRA_DIST		= autogen.sh README.md README-MAC-ARM.md \
			  BENCHMARKS.md RESEARCH.md AGENTS.md

bin_PROGRAMS = ccminer

ccminer_SOURCES	= elist.h miner.h compat.h \
			  bignum.cpp bignum.hpp \
			  ccminer.cpp pools.cpp util.cpp bench.cpp \
			  api.cpp hashlog.cpp stats.cpp sysinfos.cpp \
			  verus/stratum.cpp verus/verusscan.cpp \
			  verus/haraka.c verus/verus_clhash.cpp

ccminer_CPPFLAGS = @ARCH_FLAGS@ $(CPPFLAGS)
ccminer_CXXFLAGS = -std=c++11 @ARCH_FLAGS@
