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
	"os"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/app"
	xbc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/bitcoinplus"
	divi "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/divi"
	ppc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/peercoin"
	rpd "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/rapids"
	rdd "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/reddcoin"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/conf"

	// "encoding/json"
	// "fmt"
	"github.com/spf13/cobra"
	"log"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/wallet"
	// "io/ioutil"
	// "log"
	// "net/http"
	// be "richardmace.co.uk/boxwallet/cmd/cli/cmd/bend"
	// "strings"
)

// unlockCmd represents the unlock command
var unlockCmd = &cobra.Command{
	Use:   "unlock",
	Short: "Unlock wallet",
	Long:  ``,
	Run: func(cmd *cobra.Command, args []string) {
		var app app.App

		fmt.Println("  ____          __          __   _ _      _   \n |  _ \\         \\ \\        / /  | | |    | |  \n | |_) | _____  _\\ \\  /\\  / /_ _| | | ___| |_ \n |  _ < / _ \\ \\/ /\\ \\/  \\/ / _` | | |/ _ \\ __|\n | |_) | (_) >  <  \\  /\\  / (_| | | |  __/ |_ \n |____/ \\___/_/\\_\\  \\/  \\/ \\__,_|_|_|\\___|\\__| v" + app.Version() + "\n                                              \n                                               ")

		var conf conf.Conf
		var walletSecurityState wallet.WalletSecurityState
		var walletUnlock wallet.WalletUnlock

		appHomeDir, err := app.HomeFolder()
		if err != nil {
			log.Fatal("Unable to get HomeFolder: " + err.Error())
		}

		conf.Bootstrap(appHomeDir)

		appFileName, err := app.FileName()
		if err != nil {
			log.Fatal("Unable to get appFilename: " + err.Error())
		}

		// Make sure the config file exists, and if not, force user to use "coin" command first..
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
			//walletUnlock = xbc.XBC{}
		case models.PTDenarius:
		case models.PTDeVault:
		case models.PTDigiByte:
		case models.PTDivi:
			walletSecurityState = divi.Divi{}
			walletUnlock = divi.Divi{}
		case models.PTFeathercoin:
		case models.PTGroestlcoin:
		case models.PTPhore:
		case models.PTPeercoin:
			walletSecurityState = ppc.Peercoin{}
			walletUnlock = ppc.Peercoin{}
		case models.PTPIVX:
		case models.PTRapids:
			walletSecurityState = rpd.Rapids{}
			//walletUnlock = rpd.Rapids{}
		case models.PTReddCoin:
			walletSecurityState = rdd.ReddCoin{}
			walletUnlock = rdd.ReddCoin{}
		case models.PTScala:
		case models.PTTrezarcoin:
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

		if err := walletUnlock.WalletUnlock(&coinAuth, wep); err != nil {
			log.Fatal("failed to unlock wallet for staking: ", err.Error())
		}

		fmt.Println("Wallet unlocked!")

		// cliConf, err := be.GetConfigStruct("", true)
		// if err != nil {
		// 	log.Fatal("Unable to GetCLIConfStruct " + err.Error())
		// }

		// // Check to make sure wallet is actually encrypted
		// wi, err := be.GetWalletInfoDivi(&cliConf)
		// if err != nil {
		// 	log.Fatal("Unable to getWalletInfo " + err.Error())
		// }

		// if wi.Result.EncryptionStatus == be.CWalletESUnencrypted {
		// 	log.Fatal("Wallet is not encrypted")
		// }

		// wep := be.GetWalletEncryptionPassword()
		// r, err := unlockWallet(&cliConf, wep)
		// if err != nil || r.Error != nil {
		// 	log.Fatalf("failed to unlock wallet %s\n", err)
		// }
		// fmt.Println("Wallet unlocked")

	},
}

func init() {
	walletCmd.AddCommand(unlockCmd)

	// Here you will define your flags and configuration settings.

	// Cobra supports Persistent Flags which will work for this command
	// and all subcommands, e.g.:
	// unlockCmd.PersistentFlags().String("foo", "", "A help for foo")

	// Cobra supports local flags which will only run when this command
	// is called directly, e.g.:
	// unlockCmd.Flags().BoolP("toggle", "t", false, "Help message for toggle")
}

// func unlockWallet(cliConf *be.ConfStruct, pw string) (be.GenericRespStruct, error) {
// 	var respStruct be.GenericRespStruct

// 	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"walletpassphrase\",\"params\":[\"" + pw + "\",300]}")
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
