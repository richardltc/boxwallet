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

	// gwc "github.com/richardltc/gwcommon"
	"github.com/spf13/cobra"
)

// encryptCmd represents the encrypt command
var encryptCmd = &cobra.Command{
	Use:   "encrypt",
	Short: "Encrypts your wallet",
	Long:  ``,
	Run: func(cmd *cobra.Command, args []string) {
		// Lets load our config file first, to see if the user has made their coin choice...
		cliConf, err := be.GetConfigStruct("", true)
		if err != nil {
			log.Fatal("Unable to determine coin type. Please run " + be.CAppFilename + " coin" + err.Error())
		}

		sCoinDaemonName, err := be.GetCoinDaemonFilename(be.APPTCLI)
		if err != nil {
			log.Fatal("Unable to GetCoinDaemonFilename " + err.Error())
		}

		// Check wallet encryption status
		wi, err := be.GetWalletInfoDivi(&cliConf)
		if err != nil {
			log.Fatal("Unable to getWalletInfo " + err.Error())
		}

		if (wi.Result.EncryptionStatus != "unencrypted") && (wi.Result.EncryptionStatus != "") {
			log.Fatal("Wallet is already encrypted")
		}

		wep := be.GetPasswordToEncryptWallet()
		r, err := encryptWallet(&cliConf, wep)
		if err != nil {
			log.Fatalf("failed to encrypt wallet %s\n", err)
		}
		fmt.Println(r.Result)
		// Start the coin daemon server if required...
		if err := be.RunCoinDaemon(true); err != nil {
			log.Fatalf("failed to run "+sCoinDaemonName+": %v", err)
		}

		// sAppCLIName, err := gwc.GetAppCLIName() // e.g. GoDivi CLI
		// if err != nil {
		// 	log.Fatal("Unable to GetAppCLIName " + err.Error())
		// }

		// sAppFileCLIName, err := gwc.GetAppFileName(gwc.APPTCLI)
		// if err != nil {
		// 	log.Fatal("Unable to GetAppFileCLIName " + err.Error())
		// }
		// sCoinDaemonFile, err := gwc.GetCoinDaemonFilename()
		// if err != nil {
		// 	log.Fatal("Unable to GetCoinDaemonFilename " + err.Error())
		// }

		// // Check to make sure we're installed
		// if !gwc.IsGoWalletInstalled() { //DiviInstalled() {
		// 	log.Fatal(sAppCLIName + ` doesn't appear to be installed yet. Please run "` + sAppFileCLIName + ` install" first`)
		// }

		// // Start the Coin Daemon server if required...
		// err = gwc.RunCoinDaemon(true) //DiviD(true)
		// if err != nil {
		// 	log.Fatalf("failed to run "+sCoinDaemonFile+": %v", err)
		// }

		// wi, err := gwc.GetWalletInfo(true)
		// if err != nil {
		// 	log.Fatalf("error getting wallet info: %v", err)
		// }

		// fmt.Println("Wallet status is: " + wi.EncryptionStatus)
		// if wi.EncryptionStatus != "unencrypted" {
		// 	log.Fatalf("Looks like your wallet is already encrypted")
		// }

		// abf, _ := gwc.GetAppsBinFolder()
		// resp := gwc.GetEncryptWalletResp()
		// if resp == "y" {
		// 	wep := gwc.GetWalletEncryptionPassword()
		// 	_, err := gwc.RunDCCommandWithValue(abf+sAppFileCLIName, gwc.CCommandEncryptWallet, wep, "Waiting for wallet to respond. This could take several minutes...", 30)

		// 	if err != nil {
		// 		log.Fatalf("cmd.Run() failed with %s\n", err)
		// 	}
		// 	fmt.Println("Restarting wallet after encryption...")
		// 	err = gwc.StopCoinDaemon() //DiviD()
		// 	if err != nil {
		// 		log.Fatalf("failed to stop "+sCoinDaemonFile+": %v", err)
		// 	}
		// 	err = gwc.RunCoinDaemon(false) //DiviD(false)
		// 	if err != nil {
		// 		log.Fatalf("failed to run "+sCoinDaemonFile+": %v", err)
		// 	}

		// }

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
