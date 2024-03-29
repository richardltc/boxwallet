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
	// "fmt"
	"log"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/coins"
	xbc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/bitcoinplus"
	btcz "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/bitcoinz"
	divi "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/divi"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/dogecash"
	ftc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/feathercoin"
	ltc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/litecoin"
	ppc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/peercoin"
	rpd "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/rapids"
	rdd "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/reddcoin"
	sbyte "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/spiderbyte"
	tzc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/trezarcoin"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/wallet"

	// be "richardmace.co.uk/boxwallet/cmd/cli/cmd/bend"

	"fmt"
	"github.com/spf13/cobra"
	"os"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/app"

	"richardmace.co.uk/boxwallet/cmd/cli/cmd/conf"
)

// encryptCmd represents the encrypt command
var encryptCmd = &cobra.Command{
	Use:   "encrypt",
	Short: "Encrypts your wallet",
	Long:  ``,
	Run: func(cmd *cobra.Command, args []string) {
		var app app.App

		fmt.Println("  ____          __          __   _ _      _   \n |  _ \\         \\ \\        / /  | | |    | |  \n | |_) | _____  _\\ \\  /\\  / /_ _| | | ___| |_ \n |  _ < / _ \\ \\/ /\\ \\/  \\/ / _` | | |/ _ \\ __|\n | |_) | (_) >  <  \\  /\\  / (_| | | |  __/ |_ \n |____/ \\___/_/\\_\\  \\/  \\/ \\__,_|_|_|\\___|\\__| v" + app.Version() + "\n                                              \n                                               ")

		var conf conf.Conf
		var coinName coins.CoinName
		var daemonRunning coins.CoinDaemon
		var walletSecurityState wallet.WalletSecurityState
		var walletEncrypt wallet.WalletEncrypt

		appHomeDir, err := app.HomeFolder()
		if err != nil {
			log.Fatal("Unable to get HomeFolder: " + err.Error())
		}

		conf.Bootstrap(appHomeDir)

		appFileName, err := app.FileName()
		if err != nil {
			log.Fatal("Unable to get appFilename: " + err.Error())
		}

		// Make sure the config file exists, and if not, force user to use "coin" command first.
		if _, err := os.Stat(appHomeDir + conf.ConfFile()); os.IsNotExist(err) {
			log.Fatal("Unable to determine coin type. Please run " + appFileName + " coin  first")
		}

		// Now load our config file to see what coin choice the user made.
		confDB, err := conf.GetConfig(true)
		if err != nil {
			log.Fatal("Unable to determine coin type. Please run " + appFileName + " coin: " + err.Error())
		}

		switch confDB.ProjectType {
		case models.PTBitcoinPlus:
			coinName = xbc.XBC{}
			daemonRunning = xbc.XBC{}
			walletSecurityState = xbc.XBC{}
			walletEncrypt = xbc.XBC{}
		case models.PTBitcoinZ:
			coinName = btcz.Bitcoinz{}
			daemonRunning = btcz.Bitcoinz{}
			walletSecurityState = btcz.Bitcoinz{}
			walletEncrypt = btcz.Bitcoinz{}
		case models.PTDenarius:
		case models.PTDeVault:
		case models.PTDigiByte:
		case models.PTDivi:
			coinName = divi.Divi{}
			daemonRunning = divi.Divi{}
			walletSecurityState = divi.Divi{}
			walletEncrypt = divi.Divi{}
		case models.PTDogeCash:
			coinName = dogecash.DogeCash{}
			daemonRunning = dogecash.DogeCash{}
			walletSecurityState = dogecash.DogeCash{}
			walletEncrypt = dogecash.DogeCash{}
		case models.PTFeathercoin:
			coinName = ftc.Feathercoin{}
			daemonRunning = ftc.Feathercoin{}
			walletSecurityState = ftc.Feathercoin{}
			walletEncrypt = ftc.Feathercoin{}
		case models.PTGroestlcoin:
		case models.PTLitecoin:
			coinName = ltc.Litecoin{}
			daemonRunning = ltc.Litecoin{}
			walletSecurityState = ltc.Litecoin{}
			walletEncrypt = ltc.Litecoin{}
		case models.PTPeercoin:
			coinName = ppc.Peercoin{}
			daemonRunning = ppc.Peercoin{}
			walletSecurityState = ppc.Peercoin{}
			walletEncrypt = ppc.Peercoin{}
		case models.PTPhore:
		case models.PTPIVX:
		case models.PTRapids:
			coinName = rpd.Rapids{}
			daemonRunning = rpd.Rapids{}
			walletSecurityState = rpd.Rapids{}
			walletEncrypt = rpd.Rapids{}
		case models.PTReddCoin:
			coinName = rdd.ReddCoin{}
			daemonRunning = rdd.ReddCoin{}
			walletSecurityState = rdd.ReddCoin{}
			walletEncrypt = rdd.ReddCoin{}
		case models.PTScala:
		case models.PTSpiderByte:
			coinName = sbyte.SpiderByte{}
			daemonRunning = sbyte.SpiderByte{}
			walletSecurityState = sbyte.SpiderByte{}
			walletEncrypt = sbyte.SpiderByte{}
		case models.PTTrezarcoin:
			coinName = tzc.Trezarcoin{}
			daemonRunning = tzc.Trezarcoin{}
			walletSecurityState = tzc.Trezarcoin{}
			walletEncrypt = tzc.Trezarcoin{}
		case models.PTVertcoin:
		default:
			log.Fatal("unable to determine ProjectType")
		}

		var coinAuth models.CoinAuth
		coinAuth.RPCUser = confDB.RPCuser
		coinAuth.RPCPassword = confDB.RPCpassword
		coinAuth.IPAddress = confDB.ServerIP
		coinAuth.Port = confDB.Port

		// Check to see if we are running the coin daemon locally, and if we are, make sure it's actually running
		// before attempting to connect to it.
		if coinAuth.IPAddress == "127.0.0.1" {
			bCDRunning, err := daemonRunning.DaemonRunning()
			if err != nil {
				log.Fatal("Unable to determine if coin daemon is running: " + err.Error())
			}
			if !bCDRunning {
				log.Fatal("Unable to communicate with the " + coinName.CoinName() + " server. Please make sure the " + coinName.CoinName() + " server is running, by running:\n\n" +
					appFileName + " start\n\n")
			}
		}

		wst, err := walletSecurityState.WalletSecurityState(&coinAuth)
		if err != nil {
			log.Fatal("Unable to determine Wallet Security State: " + err.Error())
		}
		if wst != models.WETUnencrypted {
			log.Fatal("Wallet is already encrypted")
		}

		wep := wallet.GetWalletEncryptionPasswordFresh()
		if wep == "" {
			log.Fatal("Password was blank or didn't match")
		}

		r, err := walletEncrypt.WalletEncrypt(&coinAuth, wep)
		if err != nil {
			log.Fatal("failed to encrypt wallet: ", err.Error())
		}

		fmt.Println(r.Result)
	},
}

func init() {
	walletCmd.AddCommand(encryptCmd)

	// Here you will define your flags and configuration settings.

	// Cobra supports Persistent Flags which will work for this command
	// and all subcommands, e.g.:
	// encryptCmd.PersistentFlags().String("foo", "", "A help for foo")

	// Cobra supports local flags which will only run when this command
	// is called directly, e.g.:
	// encryptCmd.Flags().BoolP("toggle", "t", false, "Help message for toggle")
}
