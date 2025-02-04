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
	// "strconv"
	// "time"

	"fmt"
	"github.com/spf13/cobra"
	"log"
	"os"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/app"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/coins"
	xbc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/bitcoinplus"
	btcz "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/bitcoinz"
	dvt "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/devault"
	divi "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/divi"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/dogecash"
	ftc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/feathercoin"
	grs "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/groestlcoin"
	ltc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/litecoin"
	nav "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/navcoin"
	nexa "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/nexa"
	ppc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/peercoin"
	pivx "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/pivx"
	xpm "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/primecoin"
	rpd "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/rapids"
	rdd "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/reddcoin"
	sbyte "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/spiderbyte"
	sys "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/syscoin"
	tzc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/trezarcoin"
	zano "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/zano"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/conf"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
	"strconv"
	"time"
)

// stopCmd represents the stop command.
var stopCmd = &cobra.Command{
	Use:   "stop",
	Short: "Stops your chosen coin's daemon server",
	Long:  ``,
	Run: func(cmd *cobra.Command, args []string) {
		var app app.App

		fmt.Println("  ____          __          __   _ _      _   \n |  _ \\         \\ \\        / /  | | |    | |  \n | |_) | _____  _\\ \\  /\\  / /_ _| | | ___| |_ \n |  _ < / _ \\ \\/ /\\ \\/  \\/ / _` | | |/ _ \\ __|\n | |_) | (_) >  <  \\  /\\  / (_| | | |  __/ |_ \n |____/ \\___/_/\\_\\  \\/  \\/ \\__,_|_|_|\\___|\\__| v" + app.Version() + "\n                                              \n                                               ")

		var conf conf.Conf
		var coinDaemon coins.CoinDaemon

		appHomeDir, err := app.HomeFolder()
		if err != nil {
			log.Fatal("Unable to get app.HomeFolder: " + err.Error())
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
			coinDaemon = xbc.XBC{}
		case models.PTBitcoinZ:
			coinDaemon = btcz.Bitcoinz{}
		case models.PTDenarius:
		case models.PTDeVault:
			coinDaemon = dvt.DeVault{}
		case models.PTDigiByte:
		case models.PTDivi:
			coinDaemon = divi.Divi{}
		case models.PTDogeCash:
			coinDaemon = dogecash.DogeCash{}
		case models.PTFeathercoin:
			coinDaemon = ftc.Feathercoin{}
		case models.PTGroestlcoin:
			coinDaemon = grs.Groestlcoin{}
		case models.PTLitecoin:
			coinDaemon = ltc.Litecoin{}
		case models.PTNavcoin:
			coinDaemon = nav.Navcoin{}
		case models.PTNexa:
			coinDaemon = nexa.Nexa{}
		case models.PTPeercoin:
			coinDaemon = ppc.Peercoin{}
		case models.PTPhore:
		case models.PTPIVX:
			coinDaemon = pivx.PIVX{}
		case models.PTPrimecoin:
			coinDaemon = xpm.Primecoin{}
		case models.PTRapids:
			coinDaemon = rpd.Rapids{}
		case models.PTReddCoin:
			coinDaemon = rdd.ReddCoin{}
		case models.PTScala:
		case models.PTSpiderByte:
			coinDaemon = sbyte.SpiderByte{}
		case models.PTSyscoin:
			coinDaemon = sys.Syscoin{}
		case models.PTTrezarcoin:
			coinDaemon = tzc.Trezarcoin{}
		case models.PTVertcoin:
		case models.PTZano:
			coinDaemon = zano.Zano{}
		default:
			log.Fatal("unable to determine ProjectType")
		}

		var coinAuth models.CoinAuth
		coinAuth.RPCUser = confDB.RPCuser
		coinAuth.RPCPassword = confDB.RPCpassword
		coinAuth.IPAddress = confDB.ServerIP
		coinAuth.Port = confDB.Port

		running, _ := coinDaemon.DaemonRunning()
		if !running {
			log.Fatal("The " + coinDaemon.DaemonFilename() + " is not running.")

		}

		fmt.Println("Stopping the " + coinDaemon.DaemonFilename() + " server...")
		// Stop the coin daemon server.
		if err := coinDaemon.StopDaemon(&coinAuth); err != nil {
			log.Fatalf("failed to run "+coinDaemon.DaemonFilename()+": %v", err)
		}
		time.Sleep(1 * time.Second)

		for i := 0; i < 600; i++ {
			b, _ := coinDaemon.DaemonRunning()
			if b {
				_ = coinDaemon.StopDaemon(&coinAuth)
				fmt.Printf("\r" + "Waiting for " + coinDaemon.DaemonFilename() + " to stop. This could take a long time on slower devices... " + strconv.Itoa(i+1))
				time.Sleep(1 * time.Second)
			} else {
				fmt.Println("\n" + coinDaemon.DaemonFilename() + " server stopped.")
				break
			}
		}

	},
}

func init() {
	rootCmd.AddCommand(stopCmd)

	// Here you will define your flags and configuration settings.

	// Cobra supports Persistent Flags which will work for this command
	// and all subcommands, e.g.:
	// stopCmd.PersistentFlags().String("foo", "", "A help for foo")

	// Cobra supports local flags which will only run when this command
	// is called directly, e.g.:
	// stopCmd.Flags().BoolP("toggle", "t", false, "Help message for toggle")
}
