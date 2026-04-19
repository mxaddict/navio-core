// Copyright (c) 2022 The Bitcoin Core developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or https://www.opensource.org/licenses/mit-license.php.

#include <streams.h>
#include <test/util/setup_common.h>
#include <wallet/db.h>
#include <wallet/test/util.h>
#include <wallet/wallet.h>

#include <boost/test/unit_test.hpp>

namespace wallet {

static bool HasAnyRecordOfType(WalletDatabase& db, const std::string& key)
{
    std::unique_ptr<DatabaseBatch> batch = db.MakeBatch(false);
    BOOST_CHECK(batch);
    std::unique_ptr<DatabaseCursor> cursor = batch->GetNewCursor();
    BOOST_CHECK(cursor);
    while (true) {
        DataStream ssKey{};
        DataStream ssValue{};
        DatabaseCursor::Status status = cursor->Next(ssKey, ssValue);
        assert(status != DatabaseCursor::Status::FAIL);
        if (status == DatabaseCursor::Status::DONE) break;
        std::string type;
        ssKey >> type;
        if (type == key) return true;
    }
    return false;
}

BOOST_AUTO_TEST_SUITE(walletload_tests)

BOOST_FIXTURE_TEST_CASE(wallet_load_verif_crypted_blsct, TestingSetup)
{
    // The test duplicates the db so each case has its own db instance.
    int NUMBER_OF_TESTS = 5;
    std::vector<std::unique_ptr<WalletDatabase>> dbs;
    blsct::PrivateKey viewKey, spendKey, tokenKey;
    blsct::DoublePublicKey dest;

    auto get_db = [](std::vector<std::unique_ptr<WalletDatabase>>& dbs) {
        std::unique_ptr<WalletDatabase> db = std::move(dbs.back());
        dbs.pop_back();
        return db;
    };

    { // Context setup.
        // Create and encrypt blsct wallet
        std::shared_ptr<CWallet> wallet(new CWallet(m_node.chain.get(), "", CreateMockableWalletDatabase()));
        wallet->InitWalletFlags(wallet::WALLET_FLAG_BLSCT);
        LOCK(wallet->cs_wallet);
        auto blsct_km = wallet->GetOrCreateBLSCTKeyMan();
        BOOST_CHECK(blsct_km->SetupGeneration({}, blsct::IMPORT_MASTER_KEY, true));

        // Get the keys in the wallet before encryption
        auto masterKeysMetadata = blsct_km->GetHDChain();
        blsct::SubAddress recvAddress = blsct_km->GetSubAddress();
        dest = recvAddress.GetKeys();
        viewKey = blsct_km->viewKey;
        BOOST_CHECK(viewKey.IsValid());
        BOOST_CHECK(blsct_km->GetKey(masterKeysMetadata.spend_id, spendKey));
        BOOST_CHECK(blsct_km->GetKey(masterKeysMetadata.token_id, tokenKey));

        // Encrypt the wallet and duplicate database
        BOOST_CHECK(wallet->EncryptWallet("encrypt"));
        wallet->Flush();

        for (int i = 0; i < NUMBER_OF_TESTS; i++) {
            dbs.emplace_back(DuplicateMockDatabase(wallet->GetDatabase()));
        }
    }

    {
        // First test case:
        // Erase all the crypted keys from db and unlock the wallet.
        // The wallet will only re-write the crypted keys to db if any checksum is missing at load time.
        // So, if any 'cblsctkey' record re-appears on db, then the checksums were not properly calculated, and we are re-writing
        // the records every time that 'CWallet::Unlock' gets called, which is not good.

        // Load the wallet and check that is encrypted

        std::shared_ptr<CWallet> wallet(new CWallet(m_node.chain.get(), "", get_db(dbs)));

        BOOST_CHECK_EQUAL(wallet->LoadWallet(), DBErrors::LOAD_OK);
        BOOST_CHECK(wallet->IsCrypted());
        BOOST_CHECK(HasAnyRecordOfType(wallet->GetDatabase(), DBKeys::CRYPTED_BLSCTKEY));

        // Now delete all records and check that the 'Unlock' function doesn't re-write them
        BOOST_CHECK(wallet->GetBLSCTKeyMan()->DeleteRecords());
        BOOST_CHECK(!HasAnyRecordOfType(wallet->GetDatabase(), DBKeys::CRYPTED_BLSCTKEY));
        BOOST_CHECK(wallet->Unlock("encrypt"));
        BOOST_CHECK(!HasAnyRecordOfType(wallet->GetDatabase(), DBKeys::CRYPTED_BLSCTKEY));
    }

    {
        // Second test case:
        // Verify that loading up a 'cblsctkey' with no checksum triggers a complete re-write of the crypted keys.
        std::unique_ptr<WalletDatabase> db = get_db(dbs);
        {
            std::unique_ptr<DatabaseBatch> batch = db->MakeBatch(false);
            std::pair<std::vector<unsigned char>, uint256> value;
            BOOST_CHECK(batch->Read(std::make_pair(DBKeys::CRYPTED_BLSCTKEY, spendKey.GetPublicKey()), value));

            const auto key = std::make_pair(DBKeys::CRYPTED_BLSCTKEY, spendKey.GetPublicKey());
            BOOST_CHECK(batch->Write(key, value.first, /*fOverwrite=*/true));
        }

        // Load the wallet and check that is encrypted
        std::shared_ptr<CWallet> wallet(new CWallet(m_node.chain.get(), "", std::move(db)));
        BOOST_CHECK_EQUAL(wallet->LoadWallet(), DBErrors::LOAD_OK);
        BOOST_CHECK(wallet->IsCrypted());
        BOOST_CHECK(HasAnyRecordOfType(wallet->GetDatabase(), DBKeys::CRYPTED_BLSCTKEY));

        // Now delete all cblsctkey records and check that the 'Unlock' function re-writes them
        // (this is because the wallet, at load time, found a cblsctkey record with no checksum)
        BOOST_CHECK(wallet->GetBLSCTKeyMan()->DeleteKeys());
        BOOST_CHECK(!HasAnyRecordOfType(wallet->GetDatabase(), DBKeys::CRYPTED_BLSCTKEY));
        BOOST_CHECK(wallet->Unlock("encrypt"));
        BOOST_CHECK(HasAnyRecordOfType(wallet->GetDatabase(), DBKeys::CRYPTED_BLSCTKEY));
    }

    {
        // Third test case:
        // Verify that loading up a 'cblsctkey' with an invalid checksum throws an error.
        std::unique_ptr<WalletDatabase> db = get_db(dbs);
        {
            std::unique_ptr<DatabaseBatch> batch = db->MakeBatch(false);
            std::vector<unsigned char> crypted_data;
            BOOST_CHECK(batch->Read(std::make_pair(DBKeys::CRYPTED_BLSCTKEY, spendKey.GetPublicKey()), crypted_data));

            // Write an invalid checksum
            std::pair<std::vector<unsigned char>, uint256> value = std::make_pair(crypted_data, uint256::ONE);
            const auto key = std::make_pair(DBKeys::CRYPTED_BLSCTKEY, spendKey.GetPublicKey());
            BOOST_CHECK(batch->Write(key, value, /*fOverwrite=*/true));
        }

        std::shared_ptr<CWallet> wallet(new CWallet(m_node.chain.get(), "", std::move(db)));
        BOOST_CHECK_EQUAL(wallet->LoadWallet(), DBErrors::CORRUPT);
    }

    {
        // Fourth test case:
        // Verify that loading up a 'cblsctkey' with an invalid pubkey throws an error
        std::unique_ptr<WalletDatabase> db = get_db(dbs);
        {
            CPubKey invalid_key;
            BOOST_CHECK(!invalid_key.IsValid());
            const auto key = std::make_pair(DBKeys::CRYPTED_KEY, invalid_key);
            std::pair<std::vector<unsigned char>, uint256> value;
            BOOST_CHECK(db->MakeBatch(false)->Write(key, value, /*fOverwrite=*/true));
        }

        std::shared_ptr<CWallet> wallet(new CWallet(m_node.chain.get(), "", std::move(db)));
        BOOST_CHECK_EQUAL(wallet->LoadWallet(), DBErrors::CORRUPT);
    }

    {
        // Fifth test case:
        // Verify that keys and addresses are not re-generated after encryption
        std::unique_ptr<WalletDatabase> db = get_db(dbs);
        std::shared_ptr<CWallet> wallet(new CWallet(m_node.chain.get(), "", std::move(db)));
        BOOST_CHECK_EQUAL(wallet->LoadWallet(), DBErrors::LOAD_OK);

        blsct::PrivateKey viewKey2, spendKey2, tokenKey2;
        auto blsct_km = wallet->GetBLSCTKeyMan();
        BOOST_CHECK(blsct_km != nullptr);

        // Get the keys in the wallet before encryption
        auto masterKeysMetadata = blsct_km->GetHDChain();
        blsct::SubAddress recvAddress = blsct_km->GetSubAddress();
        blsct::DoublePublicKey dest2 = recvAddress.GetKeys();
        viewKey2 = blsct_km->viewKey;
        BOOST_CHECK(viewKey.IsValid());
        BOOST_CHECK(!blsct_km->GetKey(masterKeysMetadata.spend_id, spendKey2));
        BOOST_CHECK(!blsct_km->GetKey(masterKeysMetadata.token_id, tokenKey2));
        BOOST_CHECK(wallet->Unlock("encrypt"));
        BOOST_CHECK(blsct_km->GetKey(masterKeysMetadata.spend_id, spendKey2));
        BOOST_CHECK(blsct_km->GetKey(masterKeysMetadata.token_id, tokenKey2));

        BOOST_CHECK(dest == dest2);
        BOOST_CHECK(viewKey == viewKey2);
        BOOST_CHECK(spendKey == spendKey2);
        BOOST_CHECK(tokenKey == tokenKey2);
    }
}

BOOST_AUTO_TEST_SUITE_END()

} // namespace wallet
