/*
Package cmd ...

Copyright © 2020 NAME HERE <EMAIL ADDRESS>

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
package cmd

import (
	"fmt"
	"log"
	"os"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/app"
	xbc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/bitcoinplus"
	divi "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/divi"
	ppc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/peercoin"
	pivx "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/pivx"
	rpd "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/rapids"
	rdd "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/reddcoin"
	sbyte "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/spiderbyte"
	tzc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/trezarcoin"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/conf"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/wallet"

	// "encoding/json"
	// "fmt"
	"github.com/spf13/cobra"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
	// "io/ioutil"
	// "log"
	// "net/http"
	// be "richardmace.co.uk/boxwallet/cmd/cli/cmd/bend"
	// "strings"
)

// unlockfsCmd represents the unlockfs command
var unlockfsCmd = &cobra.Command{
	Use:   "unlockfs",
	Short: "Unlock wallet for staking",
	Long:  ``,
	Run: func(cmd *cobra.Command, args []string) {
		var app app.App

		fmt.Println("  ____          __          __   _ _      _   \n |  _ \\         \\ \\        / /  | | |    | |  \n | |_) | _____  _\\ \\  /\\  / /_ _| | | ___| |_ \n |  _ < / _ \\ \\/ /\\ \\/  \\/ / _` | | |/ _ \\ __|\n | |_) | (_) >  <  \\  /\\  / (_| | | |  __/ |_ \n |____/ \\___/_/\\_\\  \\/  \\/ \\__,_|_|_|\\___|\\__| v" + app.Version() + "\n                                              \n                                               ")

		var conf conf.Conf
		var walletSecurityState wallet.WalletSecurityState
		var walletUnlockFS wallet.WalletUnlockFS

		appHomeDir, err := app.HomeFolder()
		if err != nil {
			log.Fatal("Unable to get HomeFolder: " + err.Error())
		}

		conf.Bootstrap(appHomeDir)

		appFileName, err := app.FileName()
		if err != nil {
			log.Fatal("Unable to get appFilename: " + err.Error())
		}

		// Make sure the config file exists, and if not, force user to use "coin" command first...
		if _, err := os.Stat(appHomeDir + conf.ConfFile()); os.IsNotExist(err) {
			log.Fatal("Unable to determine coin type. Please run " + appFileName + " coin  first")
		}

		// Now load our config file to see what coin choice the user made...
		confDB, err := conf.GetConfig(true)
		if err != nil {
			log.Fatal("Unable to determine coin type. Please run " + appFileName + " coin: " + err.Error())
		}

		switch confDB.ProjectType {
		case models.PTBitcoinPlus:
			walletSecurityState = xbc.XBC{}
			walletUnlockFS = xbc.XBC{}
		case models.PTDenarius:
		case models.PTDeVault:
		case models.PTDigiByte:
		case models.PTDivi:
			walletSecurityState = divi.Divi{}
			walletUnlockFS = divi.Divi{}
		case models.PTFeathercoin:
		case models.PTGroestlcoin:
		case models.PTLitecoin:
		case models.PTPhore:
		case models.PTPeercoin:
			walletSecurityState = ppc.Peercoin{}
			walletUnlockFS = ppc.Peercoin{}
		case models.PTPIVX:
			walletSecurityState = pivx.PIVX{}
			walletUnlockFS = pivx.PIVX{}
		case models.PTRapids:
			walletSecurityState = rpd.Rapids{}
			walletUnlockFS = rpd.Rapids{}
		case models.PTReddCoin:
			walletSecurityState = rdd.ReddCoin{}
			walletUnlockFS = rdd.ReddCoin{}
		case models.PTScala:
		case models.PTSpiderByte:
			walletSecurityState = sbyte.SpiderByte{}
			walletUnlockFS = sbyte.SpiderByte{}
		case models.PTTrezarcoin:
			walletSecurityState = tzc.Trezarcoin{}
			walletUnlockFS = tzc.Trezarcoin{}
		case models.PTVertcoin:
		default:
			log.Fatal("unable to determine ProjectType")
		}

		var coinAuth models.CoinAuth
		coinAuth.RPCUser = confDB.RPCuser
		coinAuth.RPCPassword = confDB.RPCpassword
		coinAuth.IPAddress = confDB.ServerIP
		coinAuth.Port = confDB.Port

		wst, err := walletSecurityState.WalletSecurityState(&coinAuth)
		if err != nil {
			log.Fatal("Unable to determine Wallet Security State: " + err.Error())
		}
		if wst == models.WETUnencrypted {
			log.Fatal("Wallet is not encrypted")
		}

		wep := wallet.GetWalletEncryptionPassword()

		if err := walletUnlockFS.WalletUnlockFS(&coinAuth, wep); err != nil {
			log.Fatal("failed to unlock wallet for staking: ", err.Error())
		}

		fmt.Println("Wallet unlocked for staking")

		// cliConf, err := be.GetConfigStruct("", true)
		// if err != nil {
		// 	log.Fatal("Unable to GetCLIConfStruct " + err.Error())
		// }

		// var wiDenarius be.DenariusGetInfoRespStruct
		// var wiPhore be.PhoreWalletInfoRespStruct
		// var wiPIVX be.PIVXWalletInfoRespStruct
		// var wiRapids be.RapidsWalletInfoRespStruct
		// var wiTrezarcoin be.TrezarcoinWalletInfoRespStruct
		// var wiXBC be.XBCWalletInfoRespStruct
		// switch cliConf.ProjectType {
		// case be.PTDenarius:
		// 	wiDenarius, err = be.GetInfoDenarius(&cliConf)
		// 	wet := be.GetWalletSecurityStateDenarius(&wiDenarius)
		// 	if wet == be.WETUnencrypted {
		// 		log.Fatal("Wallet is not encrypted")
		// 	}
		// case be.PTPhore:
		// 	wiPhore, err = be.GetWalletInfoPhore(&cliConf)
		// 	wet := be.GetWalletSecurityStatePhore(&wiPhore)
		// 	if wet == be.WETUnencrypted {
		// 		log.Fatal("Wallet is not encrypted")
		// 	}
		// case be.PTPIVX:
		// 	wiPIVX, err = be.GetWalletInfoPIVX(&cliConf)
		// 	if err != nil {
		// 		log.Fatalf("failed to call GetWalletInfoPIVX %s\n", err)
		// 	}
		// 	wet := be.GetWalletSecurityStatePIVX(&wiPIVX)
		// 	if wet == be.WETUnencrypted {
		// 		log.Fatal("Wallet is not encrypted")
		// 	}
		// case be.PTReddCoin:
		// 	wiRDD, err = be.GetWalletInfoRDD(&cliConf)
		// 	wet := be.GetWalletSecurityStateRDD(&wiRDD)
		// 	if wet == be.WETUnencrypted {
		// 		log.Fatal("Wallet is not encrypted")
		// 	}
		// case be.PTTrezarcoin:
		// 	wiTrezarcoin, err = be.GetWalletInfoTrezarcoin(&cliConf)
		// 	wet := be.GetWalletSecurityStateTrezarcoin(&wiTrezarcoin)
		// 	if wet == be.WETUnencrypted {
		// 		log.Fatal("Wallet is not encrypted")
		// 	}
		// default:
		// 	log.Fatal("unable to determine ProjectType")
		// }

		// wep := be.GetWalletEncryptionPassword()
		// r, err := unlockWalletFS(&cliConf, wep)
		// if err != nil || r.Error != nil {
		// 	log.Fatalf("failed to unlock wallet for staking %s\n", r.Error)
		// }
		// fmt.Println("Wallet unlocked for staking").

	},
}

func init() {
	walletCmd.AddCommand(unlockfsCmd)

	// Here you will define your flags and configuration settings.

	// Cobra supports Persistent Flags which will work for this command
	// and all subcommands, e.g.:
	// unlockfsCmd.PersistentFlags().String("foo", "", "A help for foo")

	// Cobra supports local flags which will only run when this command
	// is called directly, e.g.:
	// unlockfsCmd.Flags().BoolP("toggle", "t", false, "Help message for toggle")
}

// func unlockWalletFS(cliConf *be.ConfStruct, pw string) (be.GenericRespStruct, error) {
// 	var respStruct be.GenericRespStruct
// 	var body *strings.Reader

// 	switch cliConf.ProjectType {
// 	case be.PTBitcoinPlus:
// 		// BitcoinPlus, doesn't currently support the "true" parameter to unlock for staking, so we're just adding an "unlock" command here
// 		// until Peter has fixed it...
// 		// todo Fix this in the future so that it *only* unlocks for staking.
// 		body = strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"walletpassphrase\",\"params\":[\"" + pw + "\",9999999]}")
// 	case be.PTDenarius, be.PTTrezarcoin, be.PTRapids, be.PTReddCoin, be.PTPIVX:
// 		// Trezarcoin requires some 9's to be passed to unlock a wallet for staking
// 		body = strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"walletpassphrase\",\"params\":[\"" + pw + "\",9999999,true]}")
// 	default:
// 		// Most other wallets don't require this
// 		body = strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"walletpassphrase\",\"params\":[\"" + pw + "\",0,true]}")
// 	}

// 	//body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"walletpassphrase\",\"params\":[\"" + pw + "\",0,true]}")
// 	req, err := http.NewRequest("POST", "http://"+cliConf.ServerIP+":"+cliConf.Port, body)
// 	if err != nil {
// 		return respStruct, err
// 	}
// 	req.SetBasicAuth(cliConf.RPCuser, cliConf.RPCpassword)
// 	req.Header.Set("Content-Type", "text/plain;")

// 	resp, err := http.DefaultClient.Do(req)
// 	if err != nil {
// 		return respStruct, err
// 	}
// 	defer resp.Body.Close()
// 	bodyResp, err := ioutil.ReadAll(resp.Body)
// 	if err != nil {
// 		return respStruct, err
// 	}
// 	err = json.Unmarshal(bodyResp, &respStruct)
// 	if err != nil {
// 		return respStruct, err
// 	}
// 	return respStruct, nil
// }
