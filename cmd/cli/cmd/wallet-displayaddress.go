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
	// "log"
	// "os"

	// be "richardmace.co.uk/boxwallet/cmd/cli/cmd/bend"

	"fmt"
	"github.com/spf13/cobra"
	"log"
	"os"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/app"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/coins"
	xbc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/bitcoinplus"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/dogecash"
	ftc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/feathercoin"
	grs "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/groestlcoin"
	ltc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/litecoin"
	ppc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/peercoin"
	pivx "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/pivx"
	rdd "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/reddcoin"
	sbyte "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/spiderbyte"
	tzc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/trezarcoin"

	divi "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/divi"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/conf"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/wallet"
)

// displayaddressCmd represents the displayaddress command
var displayaddressCmd = &cobra.Command{
	Use:   "displayaddress",
	Short: "Displays your wallet address",
	Long:  ``,
	Run: func(cmd *cobra.Command, args []string) {
		var app app.App

		fmt.Println("  ____          __          __   _ _      _   \n |  _ \\         \\ \\        / /  | | |    | |  \n | |_) | _____  _\\ \\  /\\  / /_ _| | | ___| |_ \n |  _ < / _ \\ \\/ /\\ \\/  \\/ / _` | | |/ _ \\ __|\n | |_) | (_) >  <  \\  /\\  / (_| | | |  __/ |_ \n |____/ \\___/_/\\_\\  \\/  \\/ \\__,_|_|_|\\___|\\__| v" + app.Version() + "\n                                              \n                                               ")

		var conf conf.Conf
		var coinName coins.CoinName
		var walletAddress wallet.WalletAddress

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
			coinName = xbc.XBC{}
			walletAddress = xbc.XBC{}
		case models.PTDenarius:
		case models.PTDeVault:
		case models.PTDigiByte:
		case models.PTDivi:
			coinName = divi.Divi{}
			walletAddress = divi.Divi{}
		case models.PTDogeCash:
			coinName = dogecash.DogeCash{}
			walletAddress = dogecash.DogeCash{}
		case models.PTFeathercoin:
			coinName = ftc.Feathercoin{}
			walletAddress = ftc.Feathercoin{}
		case models.PTGroestlcoin:
			coinName = grs.Groestlcoin{}
			walletAddress = grs.Groestlcoin{}
		case models.PTLitecoin:
			coinName = ltc.Litecoin{}
			walletAddress = ltc.Litecoin{}
		case models.PTPhore:
		case models.PTPeercoin:
			coinName = ppc.Peercoin{}
			walletAddress = ppc.Peercoin{}
		case models.PTPIVX:
			coinName = pivx.PIVX{}
			walletAddress = pivx.PIVX{}
		case models.PTRapids:
		case models.PTReddCoin:
			coinName = rdd.ReddCoin{}
			walletAddress = rdd.ReddCoin{}
		case models.PTScala:
		case models.PTSpiderByte:
			coinName = sbyte.SpiderByte{}
			walletAddress = sbyte.SpiderByte{}
		case models.PTTrezarcoin:
			coinName = tzc.Trezarcoin{}
			walletAddress = tzc.Trezarcoin{}
		case models.PTVertcoin:
		default:
			log.Fatal("unable to determine ProjectType")
		}

		var coinAuth models.CoinAuth
		coinAuth.RPCUser = confDB.RPCuser
		coinAuth.RPCPassword = confDB.RPCpassword
		coinAuth.IPAddress = confDB.ServerIP
		coinAuth.Port = confDB.Port

		sAddress, err := walletAddress.WalletAddress(&coinAuth)
		if err != nil {
			log.Fatal("Unable to DisplayWalletAddress: " + err.Error())
		}

		fmt.Println("Your " + coinName.CoinName() + " address is: \n\n" + sAddress + "\n")
	},
}

func init() {
	walletCmd.AddCommand(displayaddressCmd)

	// Here you will define your flags and configuration settings.

	// Cobra supports Persistent Flags which will work for this command
	// and all subcommands, e.g.:
	// displayaddressCmd.PersistentFlags().String("foo", "", "A help for foo")

	// Cobra supports local flags which will only run when this command
	// is called directly, e.g.:
	// displayaddressCmd.Flags().BoolP("toggle", "t", false, "Help message for toggle")
}
