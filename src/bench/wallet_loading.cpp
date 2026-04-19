// Copyright (c) 2022 The Bitcoin Core developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <bench/bench.h>
#include <key.h>
#include <node/context.h>
#include <script/script.h>
#include <test/util/setup_common.h>
#include <util/translation.h>
#include <validationinterface.h>
#include <wallet/context.h>
#include <wallet/receive.h>
#include <wallet/test/util.h>
#include <wallet/wallet.h>

namespace wallet{
static void AddTx(CWallet& wallet)
{
    CKey key;
    key.MakeNewKey(true);
    CScript script = CScript() << ToByteVector(key.GetPubKey()) << OP_CHECKSIG;

    CMutableTransaction mtx;
    mtx.vout.emplace_back(COIN, script);
    mtx.vin.emplace_back();

    wallet.AddToWallet(MakeTransactionRef(mtx), TxStateInactive{});
}

static void WalletLoading(benchmark::Bench& bench)
{
    const auto test_setup = MakeNoLogFileContext<TestingSetup>();

    WalletContext context;
    context.args = &test_setup->m_args;
    context.chain = test_setup->m_node.chain.get();

    // Setup the wallet
    // Loading the wallet will also create it
    const uint64_t create_flags = WALLET_FLAG_BLSCT | WALLET_FLAG_BLANK_WALLET;
    auto database = CreateMockableWalletDatabase();
    auto wallet = TestLoadWallet(std::move(database), context, create_flags);

    // Generate a bunch of transactions to put into the wallet
    for (int i = 0; i < 1000; ++i) {
        AddTx(*wallet);
    }

    database = DuplicateMockDatabase(wallet->GetDatabase());

    // reload the wallet for the actual benchmark
    TestUnloadWallet(std::move(wallet));

    bench.epochs(5).run([&] {
        wallet = TestLoadWallet(std::move(database), context, create_flags);

        // Cleanup
        database = DuplicateMockDatabase(wallet->GetDatabase());
        TestUnloadWallet(std::move(wallet));
    });
}

static void WalletLoadingBLSCT(benchmark::Bench& bench)
{
    WalletLoading(bench);
}
BENCHMARK(WalletLoadingBLSCT, benchmark::PriorityLevel::HIGH);
} // namespace wallet
