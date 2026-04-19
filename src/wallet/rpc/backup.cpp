// Copyright (c) 2009-2022 The Bitcoin Core developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <core_io.h>
#include <interfaces/chain.h>
#include <merkleblock.h>
#include <rpc/util.h>
#include <uint256.h>
#include <util/fs.h>
#include <util/translation.h>
#include <wallet/rpc/util.h>
#include <wallet/wallet.h>

#include <string>

#include <univalue.h>

using interfaces::FoundBlock;

namespace wallet {

RPCHelpMan importprunedfunds()
{
    return RPCHelpMan{"importprunedfunds",
                "\nImports funds without rescan. Corresponding address or script must previously be included in wallet. Aimed towards pruned wallets. The end-user is responsible to import additional transactions that subsequently spend the imported outputs or rescan after the point in the blockchain the transaction is included.\n",
                {
                    {"rawtransaction", RPCArg::Type::STR_HEX, RPCArg::Optional::NO, "A raw transaction in hex funding an already-existing address in wallet"},
                    {"txoutproof", RPCArg::Type::STR_HEX, RPCArg::Optional::NO, "The hex output from gettxoutproof that contains the transaction"},
                },
                RPCResult{RPCResult::Type::NONE, "", ""},
                RPCExamples{""},
        [&](const RPCHelpMan& self, const JSONRPCRequest& request) -> UniValue
{
    std::shared_ptr<CWallet> const pwallet = GetWalletForJSONRPCRequest(request);
    if (!pwallet) return UniValue::VNULL;

    CMutableTransaction tx;
    if (!DecodeHexTx(tx, request.params[0].get_str())) {
        throw JSONRPCError(RPC_DESERIALIZATION_ERROR, "TX decode failed. Make sure the tx has at least one input.");
    }
    uint256 hashTx = tx.GetHash();

    DataStream ssMB{ParseHexV(request.params[1], "proof")};
    CMerkleBlock merkleBlock;
    ssMB >> merkleBlock;

    //Search partial merkle tree in proof for our transaction and index in valid block
    std::vector<uint256> vMatch;
    std::vector<unsigned int> vIndex;
    if (merkleBlock.txn.ExtractMatches(vMatch, vIndex) != merkleBlock.header.hashMerkleRoot) {
        throw JSONRPCError(RPC_INVALID_ADDRESS_OR_KEY, "Something wrong with merkleblock");
    }

    LOCK(pwallet->cs_wallet);
    int height;
    if (!pwallet->chain().findAncestorByHash(pwallet->GetLastBlockHash(), merkleBlock.header.GetHash(), FoundBlock().height(height))) {
        throw JSONRPCError(RPC_INVALID_ADDRESS_OR_KEY, "Block not found in chain");
    }

    std::vector<uint256>::const_iterator it;
    if ((it = std::find(vMatch.begin(), vMatch.end(), hashTx)) == vMatch.end()) {
        throw JSONRPCError(RPC_INVALID_ADDRESS_OR_KEY, "Transaction given doesn't exist in proof");
    }

    unsigned int txnIndex = vIndex[it - vMatch.begin()];

    CTransactionRef tx_ref = MakeTransactionRef(tx);
    if (pwallet->IsMine(*tx_ref)) {
        pwallet->AddToWallet(std::move(tx_ref), TxStateConfirmed{merkleBlock.header.GetHash(), height, static_cast<int>(txnIndex)});
        return UniValue::VNULL;
    }

    throw JSONRPCError(RPC_INVALID_ADDRESS_OR_KEY, "No addresses in wallet correspond to included transaction");
},
    };
}

RPCHelpMan removeprunedfunds()
{
    return RPCHelpMan{"removeprunedfunds",
                "\nDeletes the specified transaction from the wallet. Meant for use with pruned wallets and as a companion to importprunedfunds. This will affect wallet balances.\n",
                {
                    {"txid", RPCArg::Type::STR_HEX, RPCArg::Optional::NO, "The hex-encoded id of the transaction you are deleting"},
                },
                RPCResult{RPCResult::Type::NONE, "", ""},
                RPCExamples{
                    HelpExampleCli("removeprunedfunds", "\"a8d0c0184dde994a09ec054286f1ce581bebf46446a512166eae7628734ea0a5\"") +
            "\nAs a JSON-RPC call\n"
            + HelpExampleRpc("removeprunedfunds", "\"a8d0c0184dde994a09ec054286f1ce581bebf46446a512166eae7628734ea0a5\"")
                },
        [&](const RPCHelpMan& self, const JSONRPCRequest& request) -> UniValue
{
    std::shared_ptr<CWallet> const pwallet = GetWalletForJSONRPCRequest(request);
    if (!pwallet) return UniValue::VNULL;

    LOCK(pwallet->cs_wallet);

    uint256 hash(ParseHashV(request.params[0], "txid"));
    std::vector<uint256> vHash;
    vHash.push_back(hash);
    std::vector<uint256> vHashOut;

    if (pwallet->ZapSelectTx(vHash, vHashOut) != DBErrors::LOAD_OK) {
        throw JSONRPCError(RPC_WALLET_ERROR, "Could not properly delete the transaction.");
    }

    if(vHashOut.empty()) {
        throw JSONRPCError(RPC_INVALID_PARAMETER, "Transaction does not exist in wallet.");
    }

    return UniValue::VNULL;
},
    };
}

RPCHelpMan getblsctseed()
{
    return RPCHelpMan{
        "getblsctseed",
        "\nDumps the BLSCT wallet seed, which can be used to reconstruct the wallet.\n"
        "Note: This command is only compatible with BLSCT wallets.\n",
        {},
        RPCResult{
            RPCResult::Type::STR, "seed", "The BLSCT wallet seed"},
        RPCExamples{HelpExampleCli("getblsctseed", "") + HelpExampleRpc("getblsctseed", "")},
        [&](const RPCHelpMan& self, const JSONRPCRequest& request) -> UniValue {
            const std::shared_ptr<const CWallet> pwallet = GetWalletForJSONRPCRequest(request);
            if (!pwallet) return UniValue::VNULL;

            const CWallet& wallet = *pwallet;
            const blsct::KeyMan& blsct_km = EnsureConstBlsctKeyMan(wallet);

            auto seed = blsct_km.GetMasterSeedKey();
            auto strSeed = seed.GetScalar().GetString();

            if (strSeed.length() < 64) {
                strSeed.insert(0, 64 - strSeed.length(), '0');
            }

            return strSeed;
        },
    };
}


RPCHelpMan getblsctauditkey()
{
    return RPCHelpMan{
        "getblsctauditkey",
        "\nDumps the BLSCT wallet audit key, which can be used to observe the wallet history without being able to spend the transactions.\n"
        "Note: This command is only compatible with BLSCT wallets.\n",
        {},
        RPCResult{
            RPCResult::Type::STR, "auditkey", "The BLSCT wallet audit key"},
        RPCExamples{HelpExampleCli("getblsctauditkey", "") + HelpExampleRpc("getblsctauditkey", "")},
        [&](const RPCHelpMan& self, const JSONRPCRequest& request) -> UniValue {
            const std::shared_ptr<const CWallet> pwallet = GetWalletForJSONRPCRequest(request);
            if (!pwallet) return UniValue::VNULL;

            const CWallet& wallet = *pwallet;
            const blsct::KeyMan& blsct_km = EnsureConstBlsctKeyMan(wallet);

            auto strViewKey = blsct_km.GetPrivateViewKey().GetScalar().GetString();
            auto strSpendingKey = HexStr(blsct_km.GetPublicSpendingKey().GetVch());

            if (strViewKey.length() < 64) {
                strViewKey.insert(0, 64 - strViewKey.length(), '0');
            }

            if (strSpendingKey.length() < 96) {
                strSpendingKey.insert(0, 96 - strSpendingKey.length(), '0');
            }

            return strprintf("%s%s", strViewKey, strSpendingKey);
        },
    };
}


RPCHelpMan backupwallet()
{
    return RPCHelpMan{"backupwallet",
                "\nSafely copies the current wallet file to the specified destination, which can either be a directory or a path with a filename.\n",
                {
                    {"destination", RPCArg::Type::STR, RPCArg::Optional::NO, "The destination directory or file"},
                },
                RPCResult{RPCResult::Type::NONE, "", ""},
                RPCExamples{
                    HelpExampleCli("backupwallet", "\"backup.dat\"")
            + HelpExampleRpc("backupwallet", "\"backup.dat\"")
                },
        [&](const RPCHelpMan& self, const JSONRPCRequest& request) -> UniValue
{
    const std::shared_ptr<const CWallet> pwallet = GetWalletForJSONRPCRequest(request);
    if (!pwallet) return UniValue::VNULL;

    // Make sure the results are valid at least up to the most recent block
    // the user could have gotten from another RPC command prior to now
    pwallet->BlockUntilSyncedToCurrentChain();

    LOCK(pwallet->cs_wallet);

    std::string strDest = request.params[0].get_str();
    if (!pwallet->BackupWallet(strDest)) {
        throw JSONRPCError(RPC_WALLET_ERROR, "Error: Wallet backup failed!");
    }

    return UniValue::VNULL;
},
    };
}


RPCHelpMan restorewallet()
{
    return RPCHelpMan{
        "restorewallet",
        "\nRestores and loads a wallet from backup.\n"
        "\nThe rescan is significantly faster if a descriptor wallet is restored"
        "\nand block filters are available (using startup option \"-blockfilterindex=1\").\n",
        {
            {"wallet_name", RPCArg::Type::STR, RPCArg::Optional::NO, "The name that will be applied to the restored wallet"},
            {"backup_file", RPCArg::Type::STR, RPCArg::Optional::NO, "The backup file that will be used to restore the wallet."},
            {"load_on_startup", RPCArg::Type::BOOL, RPCArg::Optional::OMITTED, "Save wallet name to persistent settings and load on startup. True to add wallet to startup list, false to remove, null to leave unchanged."},
        },
        RPCResult{
            RPCResult::Type::OBJ, "", "",
            {
                {RPCResult::Type::STR, "name", "The wallet name if restored successfully."},
                {RPCResult::Type::ARR, "warnings", /*optional=*/true, "Warning messages, if any, related to restoring and loading the wallet.",
                {
                    {RPCResult::Type::STR, "", ""},
                }},
            }
        },
        RPCExamples{
            HelpExampleCli("restorewallet", "\"testwallet\" \"home\\backups\\backup-file.bak\"")
            + HelpExampleRpc("restorewallet", "\"testwallet\" \"home\\backups\\backup-file.bak\"")
            + HelpExampleCliNamed("restorewallet", {{"wallet_name", "testwallet"}, {"backup_file", "home\\backups\\backup-file.bak\""}, {"load_on_startup", true}})
            + HelpExampleRpcNamed("restorewallet", {{"wallet_name", "testwallet"}, {"backup_file", "home\\backups\\backup-file.bak\""}, {"load_on_startup", true}})
        },
        [&](const RPCHelpMan& self, const JSONRPCRequest& request) -> UniValue
{

    WalletContext& context = EnsureWalletContext(request.context);

    auto backup_file = fs::u8path(request.params[1].get_str());

    std::string wallet_name = request.params[0].get_str();

    std::optional<bool> load_on_start = request.params[2].isNull() ? std::nullopt : std::optional<bool>(request.params[2].get_bool());

    DatabaseStatus status;
    bilingual_str error;
    std::vector<bilingual_str> warnings;

    const std::shared_ptr<CWallet> wallet = RestoreWallet(context, backup_file, wallet_name, load_on_start, status, error, warnings);

    HandleWalletError(wallet, status, error);

    UniValue obj(UniValue::VOBJ);
    obj.pushKV("name", wallet->GetName());
    PushWarnings(warnings, obj);

    return obj;

},
    };
}

// RPCHelpMan importblsctscript()
// {
//     return RPCHelpMan{"importblsctscript",
//                       "\nImport BLSCT scripts for watching. Requires a new wallet backup.\n"
//                       "The imported scripts will be watch-only and cannot be used to spend.\n"
//                       "Note: This call can take over an hour to complete if rescan is true, during that time, other rpc calls\n"
//                       "may report that the imported scripts exist but related transactions are still missing.\n"
//                       "The rescan parameter can be set to false if the script was never used to create transactions. If it is set to false,\n"
//                       "but the script was used to create transactions, rescanblockchain needs to be called with the appropriate block range.\n"
//                       "Note: Use \"getwalletinfo\" to query the scanning progress.\n",
//                       {
//                           {"label", RPCArg::Type::STR, RPCArg::Default{""}, "An optional label"},
//                           {"scripts", RPCArg::Type::ARR, RPCArg::Optional::NO, "Array of scripts to import", {
//                                                                                                                  {"script", RPCArg::Type::STR, RPCArg::Optional::OMITTED, "A script"},
//                                                                                                              }},
//                           {"have_solving_data", RPCArg::Type::BOOL, RPCArg::Default{false}, "Whether the wallet has the data to solve the script"},
//                           {"apply_label", RPCArg::Type::BOOL, RPCArg::Default{false}, "Whether to apply the label to the imported scripts"},
//                           {"timestamp", RPCArg::Type::NUM, RPCArg::Default{0}, "Creation time of the script expressed in " + UNIX_EPOCH_TIME + ".\n"
//                                                                                                                                                "The timestamp of the oldest script will determine how far back blockchain rescans need to begin for missing wallet transactions.\n"
//                                                                                                                                                "0 can be specified to scan the entire blockchain. Blocks up to 2 hours before the earliest script\n"
//                                                                                                                                                "creation time of all scripts being imported will be scanned."},
//                       },
//                       RPCResult{RPCResult::Type::BOOL, "", "true if successful"},
//                       RPCExamples{HelpExampleCli("importblsctscript", "\"my label\" '[\"<script1>\", \"<script2>\"]' false true 0")},
//                       [&](const RPCHelpMan& self, const JSONRPCRequest& request) -> UniValue {
//                           std::shared_ptr<CWallet> const pwallet = GetWalletForJSONRPCRequest(request);
//                           if (!pwallet) return UniValue::VNULL;
//                           CWallet& wallet{*pwallet};

//                           // Make sure the results are valid at least up to the most recent block
//                           // the user could have gotten from another RPC command prior to now
//                           wallet.BlockUntilSyncedToCurrentChain();

//                           std::string label = request.params[0].isNull() ? "" : request.params[0].get_str();

//                           const UniValue& script_pub_keys = request.params[1];
//                           if (!script_pub_keys.isArray()) {
//                               throw JSONRPCError(RPC_TYPE_ERROR, "script_pub_keys must be an array");
//                           }

//                           std::set<CScript> scripts;
//                           for (const UniValue& script : script_pub_keys.getValues()) {
//                               if (!script.isStr()) {
//                                   throw JSONRPCError(RPC_TYPE_ERROR, "script must be a string");
//                               }

//                               std::string script_str = script.get_str();
//                               if (script_str.empty()) {
//                                   throw JSONRPCError(RPC_INVALID_PARAMETER, "Empty script provided");
//                               }

//                               // Parse the script
//                               std::vector<unsigned char> script_data;
//                               if (!IsHex(script_str)) {
//                                   throw JSONRPCError(RPC_INVALID_PARAMETER, "Invalid script: not hex");
//                               }

//                               try {
//                                   script_data = ParseHex(script_str);
//                               } catch (const std::exception& e) {
//                                   throw JSONRPCError(RPC_INVALID_PARAMETER, "Invalid script: " + std::string(e.what()));
//                               }

//                               if (script_data.empty()) {
//                                   throw JSONRPCError(RPC_INVALID_PARAMETER, "Empty script after parsing");
//                               }

//                               scripts.insert(CScript(script_data.begin(), script_data.end()));
//                           }

//                           if (scripts.empty()) {
//                               throw JSONRPCError(RPC_INVALID_PARAMETER, "No scripts provided");
//                           }

//                           bool have_solving_data = request.params[2].isNull() ? false : request.params[2].get_bool();
//                           bool apply_label = request.params[3].isNull() ? false : request.params[3].get_bool();
//                           int64_t timestamp = request.params[4].isNull() ? 0 : request.params[4].getInt<int64_t>();

//                           // Import the scripts
//                           if (!wallet.importblsctscript(label, scripts, have_solving_data, apply_label, timestamp)) {
//                               throw JSONRPCError(RPC_WALLET_ERROR, "Error importing BLSCT scripts");
//                           }

//                           return true;
//                       }};
// }
} // namespace wallet