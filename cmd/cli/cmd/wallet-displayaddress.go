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

	be "richardmace.co.uk/boxwallet/cmd/cli/cmd/bend"

	"github.com/spf13/cobra"
)

// displayaddressCmd represents the displayaddress command
var displayaddressCmd = &cobra.Command{
	Use:   "displayaddress",
	Short: "Displays your wallet address",
	Long:  ``,
	Run: func(cmd *cobra.Command, args []string) {
		cliConf, err := be.GetConfigStruct("", true)
		if err != nil {
			log.Fatal("Unable to GetCLIConfStruct " + err.Error())
		}

		sAppFileCLIName, err := be.GetAppFileName()
		if err != nil {
			log.Fatal("Unable to GetAppFileCLIName " + err.Error())
		}

		wRunning, _, err := confirmWalletReady()
		if err != nil {
			log.Fatal("Unable to determine if wallet is ready: " + err.Error())
		}

		coind, err := be.GetCoinDaemonFilename(be.APPTCLI, cliConf.ProjectType)
		if err != nil {
			log.Fatalf("Unable to GetCoinDaemonFilename - %v", err)
		}
		if !wRunning {
			fmt.Println("")
			log.Fatal("Unable to communicate with the " + coind + " server. Please make sure the " + coind + " server is running, by running:\n\n" +
				"./" + sAppFileCLIName + " start\n\n")
		}

		var sAddress string
		switch cliConf.ProjectType {
		case be.PTDivi:
			addresses, _ := be.ListReceivedByAddressDivi(&cliConf, true)
			if len(addresses.Result) > 0 {
				sAddress = addresses.Result[0].Address
			} else {
				r, err := be.GetNewAddressDivi(&cliConf)
				if err != nil {
					log.Fatalf("Unable to GetNewAddressDivi")
				}
				sAddress = r.Result
			}
		case be.PTFeathercoin:
			addresses, _ := be.ListReceivedByAddressFeathercoin(&cliConf, true)
			if len(addresses.Result) > 0 {
				sAddress = addresses.Result[0].Address
			} else {
				r, err := be.GetNewAddressFeathercoin(&cliConf)
				if err != nil {
					log.Fatalf("Unable to GetNewAddressFeathercoin")
				}
				sAddress = r.Result
			}
		case be.PTGroestlcoin:
			addresses, _ := be.ListReceivedByAddressGRS(&cliConf, true)
			if len(addresses.Result) > 0 {
				sAddress = addresses.Result[0].Address
			} else {
				r, err := be.GetNewAddressGRS(&cliConf)
				if err != nil {
					log.Fatalf("Unable to GetNewAddressGRS")
				}
				sAddress = r.Result
			}
		case be.PTPhore:
			addresses, _ := be.ListReceivedByAddressPhore(&cliConf, true)
			if len(addresses.Result) > 0 {
				sAddress = addresses.Result[0].Address
			}
		case be.PTPIVX:
			addresses, _ := be.ListReceivedByAddressPIVX(&cliConf, true)
			if len(addresses.Result) > 0 {
				sAddress = addresses.Result[0].Address
			} else {
				r, err := be.GetNewAddressPIVX(&cliConf)
				if err != nil {
					log.Fatalf("Unable to GetNewAddressPIVX")
				}
				sAddress = r.Result
			}
		case be.PTRapids:
			addresses, _ := be.ListReceivedByAddressRapids(&cliConf, true)
			if len(addresses.Result) > 0 {
				sAddress = addresses.Result[0].Address
			}
		case be.PTReddCoin:
			addresses, _ := be.ListReceivedByAddressRDD(&cliConf, true)
			if len(addresses.Result) > 0 {
				sAddress = addresses.Result[0].Address
			} else {
				r, err := be.GetNewAddressRDD(&cliConf)
				if err != nil {
					log.Fatalf("Unable to call GetNewAddressRDD")
				}
				sAddress = r.Result[0].Address
			}
		case be.PTTrezarcoin:
			addresses, _ := be.ListReceivedByAddressTrezarcoin(&cliConf, true)
			if len(addresses.Result) > 0 {
				sAddress = addresses.Result[0].Address
			}
		default:
			log.Fatalf("Unable to determine project type")
		}

		cn, err := be.GetCoinName(be.APPTCLI)
		if err != nil {
			log.Fatalf("Unable to call GetCoinName")
		}

		fmt.Println("Your " + cn + " address is: \n\n" + sAddress + "\n")

		// sAppCLIName, err := gwc.GetAppCLIName() // e.g. GoDivi CLI
		// if err != nil {
		// 	log.Fatal("Unable to GetAppCLIName " + err.Error())
		// }
		// sAppFileCLIName, err := gwc.GetAppFileName(gwc.APPTCLI)
		// if err != nil {
		// 	log.Fatal("Unable to GetAppFileCLIName " + err.Error())
		// }

		// // Check to make sure we're installed
		// if !gwc.IsGoWalletInstalled() {
		// 	log.Fatal(sAppCLIName + ` doesn't appear to be installed yet. Please run "` + sAppFileCLIName + ` install" first`)
		// }

		// Start the Coin Daemon service if required...
		// err = gwc.StartCoinDaemon(true)
		// if err != nil {
		// 	log.Fatalf("failed to run the coin daemon: %v", err)
		// }
		// wa, err := gwc.GetWalletAddress(10)
		// if err != nil {
		// 	log.Fatalf("unable to get wallet address: %v", err)
		// }
		//fmt.Printf("\nYour address has been received:\n\n")
		//fmt.Println(wa)
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
