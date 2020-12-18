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
	"github.com/spf13/cobra"
	"io/ioutil"
	"log"
	"net/http"
	be "richardmace.co.uk/boxwallet/cmd/cli/cmd/bend"
	"strings"
)

// unlockfsCmd represents the unlockfs command
var unlockfsCmd = &cobra.Command{
	Use:   "unlockfs",
	Short: "Unlock wallet for staking",
	Long:  ``,
	Run: func(cmd *cobra.Command, args []string) {
		cliConf, err := be.GetConfigStruct("", true)
		if err != nil {
			log.Fatal("Unable to GetCLIConfStruct " + err.Error())
		}

		var wiDivi be.DiviWalletInfoRespStruct
		var wiPhore be.PhoreWalletInfoRespStruct
		var wiTrezarcoin be.TrezarcoinWalletInfoRespStruct
		switch cliConf.ProjectType {
		case be.PTDivi:
			wet := be.GetWalletSecurityStateDivi(&wiDivi)
			if wet == be.WETUnlocked {
				log.Fatal("Wallet is not encrypted")
			}
		case be.PTPhore:
			wet := be.GetWalletSecurityStatePhore(&wiPhore)
			if wet == be.WETUnlocked {
				log.Fatal("Wallet is not encrypted")
			}
		case be.PTTrezarcoin:
			wet := be.GetWalletSecurityStateTrezarcoin(&wiTrezarcoin)
			if wet == be.WETUnlocked {
				log.Fatal("Wallet is not encrypted")
			}
		default:
			log.Fatal("unable to determine ProjectType")
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
		// err = gwc.StartCoinDaemon(false)
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

func unlockWalletFS(cliConf *be.ConfStruct, pw string) (be.GenericRespStruct, error) {
	var respStruct be.GenericRespStruct
	var body *strings.Reader

	switch cliConf.ProjectType {
	case be.PTTrezarcoin:
		// Trezarcoin requires some 9's to be passed to unlock a wallet for staking
		body = strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"walletpassphrase\",\"params\":[\"" + pw + "\",99999,true]}")
	default:
		// Most other wallets don't require this
		body = strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"walletpassphrase\",\"params\":[\"" + pw + "\",0,true]}")
	}

	//body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"walletpassphrase\",\"params\":[\"" + pw + "\",0,true]}")
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
