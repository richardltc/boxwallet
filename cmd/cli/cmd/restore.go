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
	"bufio"
	"fmt"
	"log"
	"os"
	be "richardmace.co.uk/boxwallet/cmd/cli/cmd/bend"
	"strings"

	//gwc "github.com/richardltc/gwcommon"
	"github.com/spf13/cobra"
)

// restoreCmd represents the restore command
var restoreCmd = &cobra.Command{
	Use:   "restore",
	Short: "Restore your wallet from your hdseed",
	Long:  ``,
	Run: func(cmd *cobra.Command, args []string) {
		// sAppCLIName, err := gwc.GetAppCLIName() // e.g. GoDivi CLI
		// if err != nil {
		// 	log.Fatal("Unable to GetAppCLIName " + err.Error())
		// }

		sAppFileCLIName, err := be.GetAppFileName()
		if err != nil {
			log.Fatal("Unable to GetAppFileCLIName " + err.Error())
		}

		// // Check to make sure we're installed
		// if !gwc.IsGoWalletInstalled() {
		// 	log.Fatal(sAppCLIName + ` doesn't appear to be installed yet. Please run "` + sAppFileCLIName + ` install" first`)
		// }

		if len(args) < 1 {
			log.Fatal(`Please pass in the hdseed to perform a restore. e.g.  "` + sAppFileCLIName + ` wallet restore <hdseed>"`)
		}

		if args[0] == "" {
			log.Fatal(`Please pass in the hdseed to perform a restore. e.g.  "` + sAppFileCLIName + ` wallet restore <hdseed>"`)
		}

		hdseed := strings.TrimSpace(args[0])
		if len(hdseed) != 128 {
			log.Fatal(`It looks like your "hdseed" is not quite the right length. Please double check and try again`)
		}

		fmt.Println("Detected hdseed was " + hdseed)

		//TODO Finish the code for restoring a wallet
		//TODO Rename wallet.dat file
	},
}

func init() {
	walletCmd.AddCommand(restoreCmd)

	// Here you will define your flags and configuration settings.

	// Cobra supports Persistent Flags which will work for this command
	// and all subcommands, e.g.:
	// restoreCmd.PersistentFlags().String("foo", "", "A help for foo")

	// Cobra supports local flags which will only run when this command
	// is called directly, e.g.:
	// restoreCmd.Flags().BoolP("toggle", "t", false, "Help message for toggle")
}

func getWalletRestoreResp() string {
	reader := bufio.NewReader(os.Stdin)
	fmt.Print(`Warning - This will overrite your existing wallet.dat file and re-sync the blockchain!

It will take a while for your restored wallet to sync and display any funds.

Restore wallet now?: (y/n)`)
	resp, _ := reader.ReadString('\n')
	resp = strings.ReplaceAll(resp, "\n", "")
	return resp
}
