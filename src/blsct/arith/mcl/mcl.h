// Copyright (c) 2022 The Navio developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

// Diverse arithmetic operations in the bls curve
// inspired by https://github.com/b-g-goodell/research-lab/blob/master/source-code/StringCT-java/src/how/monero/hodl/bulletproof/Bulletproof.java
// and https://github.com/monero-project/monero/blob/master/src/ringct/bulletproofs.cc

#ifndef NAVIO_BLSCT_ARITH_MCL_MCL_H
#define NAVIO_BLSCT_ARITH_MCL_MCL_H

#include <blsct/arith/mcl/mcl_g1point.h>
#include <blsct/arith/mcl/mcl_init.h>
#include <blsct/arith/mcl/mcl_scalar.h>
#include <blsct/arith/mcl/mcl_util.h>

/**
 * Define a variable of type `MclInit` at the beginning
 * of an execution path in order to use this set of arith classes
 */
struct Mcl {
    using Scalar = MclScalar;
    using Point = MclG1Point;
    using Util = MclUtil;
    using Init = MclInit;
};

#endif // NAVIO_BLSCT_ARITH_MCL_MCL_H
