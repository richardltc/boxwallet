/*
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
	dvt "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/devault"

	"github.com/AlecAivazis/survey/v2"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/app"
	be "richardmace.co.uk/boxwallet/cmd/cli/cmd/bend"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/coins"
	xbc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/bitcoinplus"
	denarius "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/denarius"
	dgb "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/digibyte"
	divi "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/divi"
	ftc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/feathercoin"
	grs "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/groestlcoin"
	lcp "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/litecoinplus"
	ppc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/peercoin"
	phr "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/phore"
	pivx "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/pivx"
	xpm "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/primecoin"
	rpd "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/rapids"
	rdd "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/reddcoin"
	sys "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/syscoin"
	tzc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/trezarcoin"
	vtc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/vertcoin"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/conf"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/database"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"

	"github.com/spf13/cobra"
)

// coinCmd represents the coin command
var coinCmd = &cobra.Command{
	Use:   "coin",
	Short: "Select which coin you wish to work with",
	Long:  ``,
	Run: func(cmd *cobra.Command, args []string) {
		var app app.App
		fmt.Println("  ____          __          __   _ _      _   \n |  _ \\         \\ \\        / /  | | |    | |  \n | |_) | _____  _\\ \\  /\\  / /_ _| | | ___| |_ \n |  _ < / _ \\ \\/ /\\ \\/  \\/ / _` | | |/ _ \\ __|\n | |_) | (_) >  <  \\  /\\  / (_| | | |  __/ |_ \n |____/ \\___/_/\\_\\  \\/  \\/ \\__,_|_|_|\\___|\\__| v" + app.Version() + "\n                                              \n                                               ")

		selectedCoin := ""
		logFile, _ := app.HomeFolder()
		logFile = logFile + be.CAppLogfile

		// Create the App Working folder if required.
		appWorkingDir, _ := app.HomeFolder()
		if err := os.MkdirAll(appWorkingDir, os.ModePerm); err != nil {
			log.Fatal("unable to make directory: ", err)
		}

		be.AddToLog(logFile, "coin command invoked", false)
		var cn coins.CoinName
		cn = sys.Syscoin{}
		s := cn.CoinName()

		fmt.Printf(s)

		var coinType models.ProjectType

		prompt := &survey.Select{
			Message: "Please choose your preferred coin:",
			Options: []string{coins.CCoinNameDivi,
				coins.CCoinNameBitcoinPlus,
				coins.CCoinNameDenarius,
				coins.CCoinNameDeVault,
				coins.CCoinNameDigiByte,
				coins.CCoinNameFeathercoin,
				coins.CCoinNameGroestlcoin,
				//coins.CCoinNameLitecoinPlus,
				coins.CCoinNamePeercoin,
				//coins.CCoinNamePhore,
				coins.CCoinNamePIVX,
				coins.CCoinNamePrimecoin,
				coins.CCoinNameRapids,
				coins.CCoinNameReddCoin,
				coins.CCoinNameScala,
				coins.CCoinNameSyscoin,
				coins.CCoinNameTrezarcoin,
				coins.CCoinNameVertcoin},
		}
		survey.AskOne(prompt, &selectedCoin)

		var coin coins.Coin
		var coinName coins.CoinName
		var coinRPC coins.CoinRPCDefaults

		var cliConf models.Conf
		var conf conf.Conf
		conf.Bootstrap(appWorkingDir)
		var rpcUser, rpcPassword, ipAddress string
		var err error

		ipAddress = "127.0.0.1"

		switch selectedCoin {
		case coins.CCoinNameBitcoinPlus:
			coin = xbc.XBC{}
			coinType = models.PTBitcoinPlus
			coinRPC = xbc.XBC{}
			coinName = xbc.XBC{}
		case coins.CCoinNameDenarius:
			coin = denarius.Denarius{}
			coinName = denarius.Denarius{}
			coinRPC = denarius.Denarius{}
			coinType = models.PTDenarius
		case coins.CCoinNameDeVault:
			coin = dvt.DeVault{}
			coinName = dvt.DeVault{}
			coinRPC = dvt.DeVault{}
			coinType = models.PTDeVault
		case coins.CCoinNameDigiByte:
			coin = dgb.DigiByte{}
			coinName = dgb.DigiByte{}
			coinRPC = dgb.DigiByte{}
			coinType = models.PTDigiByte
		case coins.CCoinNameDivi:
			coin = divi.Divi{}
			coinName = divi.Divi{}
			coinRPC = divi.Divi{}
			coinType = models.PTDivi
		case coins.CCoinNameFeathercoin:
			coin = ftc.Feathercoin{}
			coinName = ftc.Feathercoin{}
			coinRPC = ftc.Feathercoin{}
			coinType = models.PTFeathercoin
		case coins.CCoinNameGroestlcoin:
			coin = grs.Groestlcoin{}
			coinName = grs.Groestlcoin{}
			coinRPC = grs.Groestlcoin{}
			coinType = models.PTGroestlcoin
		case coins.CCoinNameLitecoinPlus:
			coin = lcp.LitecoinPlus{}
			coinName = lcp.LitecoinPlus{}
			coinRPC = lcp.LitecoinPlus{}
			coinType = models.PTLitecoinPlus
		case coins.CCoinNamePeercoin:
			coin = ppc.Peercoin{}
			coinName = ppc.Peercoin{}
			coinRPC = ppc.Peercoin{}
			coinType = models.PTPeercoin
		case coins.CCoinNamePhore:
			coin = phr.Phore{}
			coinName = phr.Phore{}
			coinRPC = phr.Phore{}
			coinType = models.PTPhore
		case coins.CCoinNamePIVX:
			coin = pivx.PIVX{}
			coinName = pivx.PIVX{}
			coinRPC = pivx.PIVX{}
			coinType = models.PTPIVX
		case coins.CCoinNamePrimecoin:
			coin = xpm.Primecoin{}
			coinName = xpm.Primecoin{}
			coinRPC = xpm.Primecoin{}
			coinType = models.PTPrimecoin
		case coins.CCoinNameRapids:
			coin = rpd.Rapids{}
			coinName = rpd.Rapids{}
			coinRPC = rpd.Rapids{}
			coinType = models.PTRapids
		case coins.CCoinNameReddCoin:
			coin = rdd.ReddCoin{}
			coinName = rdd.ReddCoin{}
			coinRPC = rdd.ReddCoin{}
			coinType = models.PTReddCoin
		case coins.CCoinNameScala:
			coinType = models.PTScala
		case coins.CCoinNameSyscoin:
			coin = sys.Syscoin{}
			coinName = sys.Syscoin{}
			coinRPC = sys.Syscoin{}
			coinType = models.PTSyscoin
		case coins.CCoinNameTrezarcoin:
			coin = tzc.Trezarcoin{}
			coinName = tzc.Trezarcoin{}
			coinRPC = tzc.Trezarcoin{}
			coinType = models.PTTrezarcoin
		case coins.CCoinNameVertcoin:
			coin = vtc.Vertcoin{}
			coinName = vtc.Vertcoin{}
			coinRPC = vtc.Vertcoin{}
			coinType = models.PTVertcoin
		default:
			log.Fatal("Unable to determine coin choice")
		}

		coinHomeDir, err := coin.HomeDirFullPath()
		if err != nil {
			log.Fatal("Unable to determine HomeDir")
		}

		dfRPCUser := coinRPC.RPCDefaultUsername()
		dfRPCPort := coinRPC.RPCDefaultPort()

		rpcUser, rpcPassword, err = coins.PopulateConfFile(coin.ConfFile(),
			coinHomeDir,
			dfRPCUser, dfRPCPort)
		if err != nil {
			log.Fatal("Unable to PopulateConfFile: ", err.Error())
		}

		// ...because it's possible that the conf file for this coin has already been created, we need to store the
		// returned user and password so, effectively, will either be storing the existing info, or
		// the freshly generated info.
		cliConf.ProjectType = coinType
		cliConf.RPCuser = rpcUser
		cliConf.RPCpassword = rpcPassword
		cliConf.ServerIP = ipAddress
		cliConf.Port = dfRPCPort
		if err := conf.SetConfig(cliConf); err != nil {
			log.Fatal("Unable to write to config file: ", err)
		}

		sCoinName := coinName.CoinName()

		// Now add the coin to the coin database
		var dbCoinDetails database.CoinDetails
		dbCoinDetails.Bootstrap(appWorkingDir)

		var cd models.CoinDetails
		cd.CoinType = cliConf.ProjectType
		cd.CoinName = sCoinName

		if err := dbCoinDetails.AddCoin(cd); err != nil {
			log.Fatal(err)
		}

		be.AddToLog(logFile, "checking to see if all required project files exist... ", false)

		b, err := coin.AllBinaryFilesExist(appWorkingDir)
		if err != nil {
			log.Fatal(err)
		}
		if !b {
			// Need check if the project is Denarius now, as that's only installable via snap
			if coinType == models.PTDenarius {
				log.Fatal(coins.CCoinNameDenarius + " needs to be manually installed, via the following command:" +
					"\n\n snap install denarius" + "\n\n Then run " + be.CAppFilename + " coin again")
			}

			// All or some of the project files do not exist.
			be.AddToLog(logFile, "The "+sCoinName+" CLI bin files haven't been installed yet. So installing them now...", true)
			if err := coin.DownloadCoin(appWorkingDir); err != nil {
				log.Fatal(err)
			}
			if err := coin.Install(appWorkingDir); err != nil {
				be.AddToLog(logFile, "unable to complete coin.Install: "+err.Error(), false)
				log.Fatal(err)
			}
		} else {
			be.AddToLog(logFile, "The "+sCoinName+" CLI bin files have already been installed.", true)
		}

		// I think here is the best place to check whether the user would like to download the blockchain snapshot..
		coinSupportsBCSnapshot := false
		var coinBC coins.CoinBlockchain
		switch coinType {
		case models.PTDenarius:
			coinSupportsBCSnapshot = true
			coinBC = denarius.Denarius{}
		case models.PTDivi:
			coinSupportsBCSnapshot = true
			coinBC = divi.Divi{}
		case models.PTReddCoin:
			coinSupportsBCSnapshot = true
			coinBC = rdd.ReddCoin{}
		}
		if coinSupportsBCSnapshot {
			bcdExists, _ := coinBC.BlockchainDataExists()
			if !bcdExists {
				ans := true
				prompt := &survey.Confirm{
					Message: "\nIt looks like this is a fresh install of " + coinBC.CoinName() +
						"\n\nWould you like to download the Blockchain snapshot?:",
					Default: true,
				}
				survey.AskOne(prompt, &ans)
				if ans {
					fmt.Println("Downloading blockchain snapshot...")
					if err := coinBC.DownloadBlockchain(); err != nil {
						log.Fatal("Unable to download blockchain snapshot: " + err.Error())
					}
					fmt.Println("Unarchiving blockchain snapshot...")
					if err := coinBC.UnarchiveBlockchainSnapshot(); err != nil {
						log.Fatal("Unable to unarchive blockchain snapshot: " + err.Error())
					}
				}

			}
		}
		fmt.Println("\nAll done!")
		fmt.Println("\nYou can now run './boxwallet start' and then './boxwallet dash' to view your " + sCoinName + " Dashboard")

		sInfo := "Thank you for using " + app.Name() + " to run your " + sCoinName + " wallet/node." + "\n\n" +
			app.Name() + " is FREE to use, however, all donations are most welcome at the " + sCoinName + " address below:" + "\n\n" +
			coin.TipAddress()

		fmt.Println("\n\n" + sInfo)
	},
}

func init() {
	rootCmd.AddCommand(coinCmd)

	// Here you will define your flags and configuration settings.

	// Cobra supports Persistent Flags which will work for this command
	// and all subcommands, e.g.:
	// coinCmd.PersistentFlags().String("foo", "", "A help for foo")

	// Cobra supports local flags which will only run when this command
	// is called directly, e.g.:
	// coinCmd.Flags().BoolP("toggle", "t", false, "Help message for toggle")
}
