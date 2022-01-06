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
	divi "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/divi"
	grs "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/groestlcoin"
	lcp "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/litecoinplus"
	ppc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/peercoin"
	pivx "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/pivx"
	rdd "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/reddcoin"
	sys "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/syscoin"

	"github.com/spf13/cobra"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/app"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/coins"
	xbc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/bitcoinplus"
	d "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/denarius"
	xpm "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/primecoin"
	rpd "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/rapids"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/conf"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
)

// startCmd represents the start command
var startCmd = &cobra.Command{
	Use:   "start",
	Short: "Starts you chosen coin's daemon server",
	Long:  ``,
	Run: func(cmd *cobra.Command, args []string) {
		var app app.App

		fmt.Println("  ____          __          __   _ _      _   \n |  _ \\         \\ \\        / /  | | |    | |  \n | |_) | _____  _\\ \\  /\\  / /_ _| | | ___| |_ \n |  _ < / _ \\ \\/ /\\ \\/  \\/ / _` | | |/ _ \\ __|\n | |_) | (_) >  <  \\  /\\  / (_| | | |  __/ |_ \n |____/ \\___/_/\\_\\  \\/  \\/ \\__,_|_|_|\\___|\\__| v" + app.Version() + "\n                                              \n                                               ")

		var conf conf.Conf
		//var coin coins.Coin
		var coinDaemon coins.CoinDaemon
		var coinName coins.CoinName

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

		// Now load our config file to see what coin choice the user made...
		confDB, err := conf.GetConfig(true)
		if err != nil {
			log.Fatal("Unable to determine coin type. Please run " + appFileName + " coin: " + err.Error())
		}

		switch confDB.ProjectType {
		case models.PTBitcoinPlus:
			coinDaemon = xbc.XBC{}
			coinName = xbc.XBC{}
		case models.PTDenarius:
			coinDaemon = d.Denarius{}
			coinName = d.Denarius{}
		case models.PTDeVault:
		case models.PTDigiByte:
		case models.PTDivi:
			coinDaemon = divi.Divi{}
			coinName = divi.Divi{}
			var d divi.Divi
			if err := d.AddAddNodesIfRequired(); err != nil {
				log.Fatal("Unable to add AddNodes" + err.Error())
			}
		case models.PTFeathercoin:
		case models.PTGroestlcoin:
			coinDaemon = grs.Groestlcoin{}
			coinName = grs.Groestlcoin{}
		case models.PTLitecoinPlus:
			coinDaemon = lcp.LitecoinPlus{}
			coinName = lcp.LitecoinPlus{}
		case models.PTPeercoin:
			coinDaemon = ppc.Peercoin{}
			coinName = ppc.Peercoin{}
		case models.PTPhore:
		case models.PTPIVX:
			coinDaemon = pivx.PIVX{}
			coinName = pivx.PIVX{}
		case models.PTPrimecoin:
			coinDaemon = xpm.Primecoin{}
			coinName = xpm.Primecoin{}
		case models.PTRapids:
			coinDaemon = rpd.Rapids{}
			coinName = rpd.Rapids{}
		case models.PTReddCoin:
			coinDaemon = rdd.ReddCoin{}
			coinName = rdd.ReddCoin{}
		case models.PTScala:
		case models.PTSyscoin:
			coinDaemon = sys.Syscoin{}
			coinName = sys.Syscoin{}
		case models.PTTrezarcoin:
		case models.PTVertcoin:
		default:
			log.Fatal("unable to determine ProjectType")
		}

		if confDB.ServerIP != "127.0.0.1" {
			log.Fatal("The start command can only be run on the same machine that's running the " + coinName.CoinName() + " wallet")
		}

		var coinAuth models.CoinAuth
		coinAuth.RPCUser = confDB.RPCuser
		coinAuth.RPCPassword = confDB.RPCpassword
		coinAuth.IPAddress = confDB.ServerIP
		coinAuth.Port = confDB.Port

		// Start the coin daemon server if required.
		if err := coinDaemon.StartDaemon(true, appHomeDir, &coinAuth); err != nil {
			log.Fatalf("failed to run "+coinDaemon.DaemonFilename()+": %v", err)
		}

		fmt.Println("\nNow, simply run ./" + appFileName + " dash\n\n")
	},
}

func init() {
	rootCmd.AddCommand(startCmd)

	// Here you will define your flags and configuration settings.

	// Cobra supports Persistent Flags which will work for this command
	// and all subcommands, e.g.:
	// startCmd.PersistentFlags().String("foo", "", "A help for foo")

	// Cobra supports local flags which will only run when this command
	// is called directly, e.g.:
	// startCmd.Flags().BoolP("toggle", "t", false, "Help message for toggle")
}
