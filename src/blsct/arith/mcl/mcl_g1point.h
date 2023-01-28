// Copyright (c) 2022 The Navcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef NAVCOIN_BLSCT_ARITH_MCL_MCL_G1POINT_H
#define NAVCOIN_BLSCT_ARITH_MCL_MCL_G1POINT_H

#include <stddef.h>
#include <string>
#include <vector>

#include <bls/bls384_256.h> // must include this before bls/bls.h
#include <bls/bls.h>
#include <blsct/arith/endianness.h>
#include <blsct/arith/mcl/mcl_scalar.h>
#include <boost/thread/lock_guard.hpp>
#include <boost/thread/mutex.hpp>

class MclG1Point
{
public:
    MclG1Point();
    MclG1Point(const std::vector<uint8_t>& v);
    MclG1Point(const uint256& b);
    MclG1Point(const mclBnG1& p);

    // used as static initializer/disposer
    static void Init();
    static void Dispose(); // exists for the sake of completeness. not actually used.

    MclG1Point operator=(const mclBnG1& rhs);
    MclG1Point operator+(const MclG1Point& rhs) const;
    MclG1Point operator-(const MclG1Point& rhs) const;
    MclG1Point operator*(const MclScalar& rhs) const;

    /**
     * Because  Elements cannot be used here, std::vector is used instead
     */
    std::vector<MclG1Point> operator*(const std::vector<MclScalar>& ss) const;

    bool operator==(const MclG1Point& rhs) const;
    bool operator!=(const MclG1Point& rhs) const;

    MclG1Point Double() const;
    mclBnG1 Underlying() const;

    static MclG1Point GetBasePoint();
    static MclG1Point MapToG1(const std::vector<uint8_t>& vec, const Endianness e = Endianness::Little);
    static MclG1Point MapToG1(const std::string& s, const Endianness e = Endianness::Little);
    static MclG1Point HashAndMap(const std::vector<uint8_t>& vec);
    static MclG1Point Rand();

    bool IsValid() const;
    bool IsUnity() const;

    std::vector<uint8_t> GetVch() const;
    void SetVch(const std::vector<uint8_t>& vec);

    std::string GetString(const uint8_t& radix = 16) const;
    MclScalar GetHashWithSalt(const uint64_t salt) const;

    size_t GetSerializeSize() const;

    template <typename Stream>
    void Serialize(Stream& s) const;

    template <typename Stream>
    void Unserialize(Stream& s);

    using UnderlyingType = mclBnG1;
    UnderlyingType m_p;

    static constexpr int SERIALIZATION_SIZE = 384 / 8;

private:
    static mclBnG1* m_g; // Using mclBnG1 instead of MclG1Point to get around chiken-and-egg issue
    static boost::mutex m_init_mutex;
};

#endif // NAVCOIN_BLSCT_ARITH_MCL_MCL_G1POINT_H