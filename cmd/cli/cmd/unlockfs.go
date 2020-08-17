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
	"encoding/json"
	"fmt"
	gwc "github.com/richardltc/gwcommon"
	"github.com/spf13/cobra"
	"io/ioutil"
	"log"
	"net/http"
	be "richardmace.co.uk/boxdivi/cmd/cli/cmd/bend"
	"strings"
)

// unlockfsCmd represents the unlockfs command
var unlockfsCmd = &cobra.Command{
	Use:   "unlockfs",
	Short: "Unlock wallet for staking",
	Long:  ``,
	Run: func(cmd *cobra.Command, args []string) {
		cliConf, err := gwc.GetCLIConfStruct()
		if err != nil {
			log.Fatal("Unable to GetCLIConfStruct " + err.Error())
		}

		// Check to make sure wallet is actually encrypted
		wi, err := getWalletInfo(&cliConf)
		if err != nil {
			log.Fatal("Unable to getWalletInfo " + err.Error())
		}

		if wi.Result.EncryptionStatus == cWalletESUnencrypted {
			log.Fatal("Wallet is not encrypted")
		}

		wep := be.GetWalletEncryptionPassword()
		r, err := unlockWalletFS(&cliConf, wep)
		if err != nil || r.Error != nil {
			log.Fatalf("failed to unlock wallet for staking %s\n", err)
		}
		fmt.Println("Wallet unlocked for staking")

		// pw := gwc.GetWalletUnlockPassword()

		// couldUW, err := gwc.UnlockWallet(pw, 30, true)

		// if !couldUW {
		// 	log.Fatalf("Unable to unlock wallet")
		// }

		// // Looks like this is needed...
		// gwc.ClearScreen()
		// fmt.Println("Restarting wallet after unlock for staking...")
		// err = gwc.RunCoinDaemon(false)
		// if err != nil {
		// 	log.Fatalf("failed to run "+sCoinDaemonFile+": %v", err)
		// }

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

func unlockWalletFS(cliConf *gwc.CLIConfStruct, pw string) (be.GenericRespStruct, error) {
	var respStruct be.GenericRespStruct

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"walletpassphrase\",\"params\":[\"" + pw + "\",0,true]}")
	req, err := http.NewRequest("POST", "http://"+cliConf.ServerIP+":"+cliConf.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(cliConf.RPCuser, cliConf.RPCpassword)
	req.Header.Set("Content-Type", "text/plain;")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return respStruct, err
	}
	defer resp.Body.Close()
	bodyResp, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return respStruct, err
	}
	err = json.Unmarshal(bodyResp, &respStruct)
	if err != nil {
		return respStruct, err
	}
	return respStruct, nil
}
