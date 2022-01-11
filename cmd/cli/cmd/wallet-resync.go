/*
Copyright © 2021 NAME HERE <EMAIL ADDRESS>

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
	divi "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/divi"
	grs "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/groestlcoin"
	ppc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/peercoin"
	pivx "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/pivx"
	rpd "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/rapids"
	rdd "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/reddcoin"
	sbyte "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/spiderbyte"
	tzc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/trezarcoin"

	"richardmace.co.uk/boxwallet/cmd/cli/cmd/app"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/coins"
	xbc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/bitcoinplus"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/wallet"

	"github.com/AlecAivazis/survey/v2"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/conf"

	"github.com/spf13/cobra"
)

// resyncCmd represents the resync command
var resyncCmd = &cobra.Command{
	Use:   "resync",
	Short: "Performs a resync of the complete blockchain",
	Long:  ``,
	Run: func(cmd *cobra.Command, args []string) {
		var app app.App
		var conf conf.Conf

		appHomeDir, err := app.HomeFolder()
		if err != nil {
			log.Fatal("Unable to get HomeFolder: " + err.Error())
		}

		conf.Bootstrap(appHomeDir)
		confDB, err := conf.GetConfig(false)

		var coinName coins.CoinName
		var wallet wallet.Wallet

		switch confDB.ProjectType {
		case models.PTBitcoinPlus:
			coinName = xbc.XBC{}
			wallet = xbc.XBC{}
		case models.PTDivi:
			coinName = divi.Divi{}
			wallet = divi.Divi{}
		case models.PTGroestlcoin:
			coinName = grs.Groestlcoin{}
			wallet = grs.Groestlcoin{}
		case models.PTPeercoin:
			coinName = ppc.Peercoin{}
			wallet = ppc.Peercoin{}
		case models.PTPIVX:
			coinName = pivx.PIVX{}
			wallet = pivx.PIVX{}
		case models.PTRapids:
			coinName = rpd.Rapids{}
			wallet = rpd.Rapids{}
		case models.PTReddCoin:
			coinName = rdd.ReddCoin{}
			wallet = rdd.ReddCoin{}
		case models.PTSpiderByte:
			coinName = sbyte.SpiderByte{}
			wallet = sbyte.SpiderByte{}
		case models.PTTrezarcoin:
			coinName = tzc.Trezarcoin{}
			wallet = tzc.Trezarcoin{}
		default:
			log.Fatal("Unable to determine ProjectType")
		}

		b, err := wallet.DaemonRunning()
		if err != nil {
			log.Fatal("Unable to determine if Daemon is running " + err.Error())
		}
		if b {
			log.Fatal("Please stop the daemon first, before performing a resync")
		}

		ans := false
		prompt := &survey.Confirm{
			Message: `Are you sure? Perform a resync on your ` + coinName.CoinName() + ` wallet?:`,
		}
		if err := survey.AskOne(prompt, &ans); err != nil {
			log.Fatal("Error using survey: " + err.Error())
		}
		if !ans {
			log.Fatal("reindex not attempted.")
		}
		if err := wallet.WalletResync(appHomeDir); err != nil {
			log.Fatal("Unable to perform resync: " + err.Error())
		}

		fmt.Println("Your " + coinName.CoinName() + " wallet is now syncing again. Please use ./boxwallet dash to view")

		// cn, err := be.GetCoinName(be.APPTCLI)
		// if err != nil {
		// 	log.Fatal("Unable to GetCoinName " + err.Error())
		// }

		// ans := false
		// prompt := &survey.Confirm{
		// 	Message: `Are you sure? Perform a resync on your ` + cn + ` wallet?:`,
		// }
		// if err := survey.AskOne(prompt, &ans); err != nil {
		// 	log.Fatal("Error using survey: " + err.Error())
		// }
		// if !ans {
		// 	log.Fatal("reindex not attempted.")
		// }
		// if err := be.WalletFix(be.WFTReSync, bwConf.ProjectType); err != nil {
		// 	log.Fatal("Unable to perform resync: " + err.Error())
		// }

		// fmt.Println("Your " + cn + " wallet is now syncing again. Please use ./boxwallet dash to view").
	},
}

func init() {
	walletCmd.AddCommand(resyncCmd)

	// Here you will define your flags and configuration settings.

	// Cobra supports Persistent Flags which will work for this command
	// and all subcommands, e.g.:
	// resyncCmd.PersistentFlags().String("foo", "", "A help for foo")

	// Cobra supports local flags which will only run when this command
	// is called directly, e.g.:
	// resyncCmd.Flags().BoolP("toggle", "t", false, "Help message for toggle")
}
