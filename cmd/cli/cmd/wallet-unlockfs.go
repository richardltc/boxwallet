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
	// "encoding/json"
	// "fmt"
	"github.com/spf13/cobra"
	// "io/ioutil"
	// "log"
	// "net/http"
	// be "richardmace.co.uk/boxwallet/cmd/cli/cmd/bend"
	// "strings"
)

// unlockfsCmd represents the unlockfs command
var unlockfsCmd = &cobra.Command{
	Use:   "unlockfs",
	Short: "Unlock wallet for staking",
	Long:  ``,
	Run: func(cmd *cobra.Command, args []string) {
		// cliConf, err := be.GetConfigStruct("", true)
		// if err != nil {
		// 	log.Fatal("Unable to GetCLIConfStruct " + err.Error())
		// }

		// var wiDenarius be.DenariusGetInfoRespStruct
		// var wiDivi be.DiviWalletInfoRespStruct
		// var wiPhore be.PhoreWalletInfoRespStruct
		// var wiPIVX be.PIVXWalletInfoRespStruct
		// var wiRapids be.RapidsWalletInfoRespStruct
		// var wiRDD be.RDDWalletInfoRespStruct
		// var wiTrezarcoin be.TrezarcoinWalletInfoRespStruct
		// var wiXBC be.XBCWalletInfoRespStruct
		// switch cliConf.ProjectType {
		// case be.PTBitcoinPlus:
		// 	wiXBC, err = be.GetWalletInfoXBC(&cliConf)
		// 	wet := be.GetWalletSecurityStateXBC(&wiXBC)
		// 	if wet == be.WETUnencrypted {
		// 		log.Fatal("Wallet is not encrypted")
		// 	}
		// case be.PTDenarius:
		// 	wiDenarius, err = be.GetInfoDenarius(&cliConf)
		// 	wet := be.GetWalletSecurityStateDenarius(&wiDenarius)
		// 	if wet == be.WETUnencrypted {
		// 		log.Fatal("Wallet is not encrypted")
		// 	}
		// case be.PTDivi:
		// 	wiDivi, err = be.GetWalletInfoDivi(&cliConf)
		// 	wet := be.GetWalletSecurityStateDivi(&wiDivi)
		// 	if wet == be.WETUnencrypted {
		// 		log.Fatal("Wallet is not encrypted")
		// 	}
		// case be.PTPhore:
		// 	wiPhore, err = be.GetWalletInfoPhore(&cliConf)
		// 	wet := be.GetWalletSecurityStatePhore(&wiPhore)
		// 	if wet == be.WETUnencrypted {
		// 		log.Fatal("Wallet is not encrypted")
		// 	}
		// case be.PTPIVX:
		// 	wiPIVX, err = be.GetWalletInfoPIVX(&cliConf)
		// 	if err != nil {
		// 		log.Fatalf("failed to call GetWalletInfoPIVX %s\n", err)
		// 	}
		// 	wet := be.GetWalletSecurityStatePIVX(&wiPIVX)
		// 	if wet == be.WETUnencrypted {
		// 		log.Fatal("Wallet is not encrypted")
		// 	}
		// case be.PTRapids:
		// 	wiRapids, err = be.GetWalletInfoRapids(&cliConf)
		// 	if err != nil {
		// 		log.Fatalf("failed to call getwalletinfo %s\n", err)
		// 	}
		// 	wet := be.GetWalletSecurityStateRapids(&wiRapids)
		// 	if wet == be.WETUnencrypted {
		// 		log.Fatal("Wallet is not encrypted")
		// 	}
		// case be.PTReddCoin:
		// 	wiRDD, err = be.GetWalletInfoRDD(&cliConf)
		// 	wet := be.GetWalletSecurityStateRDD(&wiRDD)
		// 	if wet == be.WETUnencrypted {
		// 		log.Fatal("Wallet is not encrypted")
		// 	}
		// case be.PTTrezarcoin:
		// 	wiTrezarcoin, err = be.GetWalletInfoTrezarcoin(&cliConf)
		// 	wet := be.GetWalletSecurityStateTrezarcoin(&wiTrezarcoin)
		// 	if wet == be.WETUnencrypted {
		// 		log.Fatal("Wallet is not encrypted")
		// 	}
		// default:
		// 	log.Fatal("unable to determine ProjectType")
		// }

		// wep := be.GetWalletEncryptionPassword()
		// r, err := unlockWalletFS(&cliConf, wep)
		// if err != nil || r.Error != nil {
		// 	log.Fatalf("failed to unlock wallet for staking %s\n", r.Error)
		// }
		// fmt.Println("Wallet unlocked for staking")

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

// func unlockWalletFS(cliConf *be.ConfStruct, pw string) (be.GenericRespStruct, error) {
// 	var respStruct be.GenericRespStruct
// 	var body *strings.Reader

// 	switch cliConf.ProjectType {
// 	case be.PTBitcoinPlus:
// 		// BitcoinPlus, doesn't currently support the "true" parameter to unlock for staking, so we're just adding an "unlock" command here
// 		// until Peter has fixed it...
// 		// todo Fix this in the future so that it *only* unlocks for staking.
// 		body = strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"walletpassphrase\",\"params\":[\"" + pw + "\",9999999]}")
// 	case be.PTDenarius, be.PTTrezarcoin, be.PTRapids, be.PTReddCoin, be.PTPIVX:
// 		// Trezarcoin requires some 9's to be passed to unlock a wallet for staking
// 		body = strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"walletpassphrase\",\"params\":[\"" + pw + "\",9999999,true]}")
// 	default:
// 		// Most other wallets don't require this
// 		body = strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"walletpassphrase\",\"params\":[\"" + pw + "\",0,true]}")
// 	}

// 	//body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"walletpassphrase\",\"params\":[\"" + pw + "\",0,true]}")
// 	req, err := http.NewRequest("POST", "http://"+cliConf.ServerIP+":"+cliConf.Port, body)
// 	if err != nil {
// 		return respStruct, err
// 	}
// 	req.SetBasicAuth(cliConf.RPCuser, cliConf.RPCpassword)
// 	req.Header.Set("Content-Type", "text/plain;")

// 	resp, err := http.DefaultClient.Do(req)
// 	if err != nil {
// 		return respStruct, err
// 	}
// 	defer resp.Body.Close()
// 	bodyResp, err := ioutil.ReadAll(resp.Body)
// 	if err != nil {
// 		return respStruct, err
// 	}
// 	err = json.Unmarshal(bodyResp, &respStruct)
// 	if err != nil {
// 		return respStruct, err
// 	}
// 	return respStruct, nil
// }
