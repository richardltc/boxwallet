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
	gwc "github.com/richardltc/gwcommon"
	"github.com/spf13/cobra"
	"log"
	"os"
	"os/exec"
	be "richardmace.co.uk/boxdivi/cmd/cli/cmd/bend"
	"strconv"
	"time"
)

// uninstallCmd represents the uninstall command
var uninstallCmd = &cobra.Command{
	Use:   "uninstall",
	Short: "*** WARNING *** this command completely removes your " + sCoinName + " wallet.",
	Long:  ``,
	Run: func(cmd *cobra.Command, args []string) {
		abf, err := gwc.GetAppsBinFolder(gwc.APPTCLI)
		if err != nil {
			log.Fatal("Unable to GetAppsBinFolder " + err.Error())
		}
		chf, err := gwc.GetCoinHomeFolder(gwc.APPTCLI)
		if err != nil {
			log.Fatal("Unable to GetCoinHomeFolder " + err.Error())
		}
		sCoinDaemonFile, err := gwc.GetCoinDaemonFilename(gwc.APPTCLI)
		if err != nil {
			log.Fatal("Unable to GetCoinDaemonFilename " + err.Error())
		}

		fmt.Println("uninstall called....")

		reader := bufio.NewReader(os.Stdin)
		fmt.Println("\n*** WARNING *** this commmand completely removes your divi wallet, and can only be restored from a seed." +
			"\n\nPlease enter the following to wallet deletion: " +
			gwc.CUninstallConfirmationStr + "\n\n")
		resp, _ := reader.ReadString('\n')
		if resp != gwc.CUninstallConfirmationStr+"\n" {
			fmt.Println("\nuser entered: " + resp + " which does't match, so exiting...")
			return
		}

		for i := 0; i < 10; i++ {
			fmt.Println("Checking if " + sCoinDaemonFile + " is running....")
			dRunning, _, _ := be.IsCoinDaemonRunning()
			if dRunning {
				fmt.Println("Attempting to stop " + sCoinDaemonFile + ".... " + strconv.Itoa(i+1) + "/10")
				if err = be.StopCoinDaemon(true); err != nil {
					time.Sleep(7 * time.Second)
				}
			} else {
				break
			}
		}

		// The coin daemon is not running so lets delete all of the directories
		fmt.Println(sCoinDaemonFile + " is not running...")

		if _, err := os.Stat(chf); !os.IsNotExist(err) {
			// It exists.. so
			fmt.Println("Attempting to rm -R " + chf + "...")
			cRun := exec.Command("rm", "-R", chf)
			if err := cRun.Run(); err != nil {
				log.Println("Error:", err)
			}
		}

		if _, err := os.Stat(abf); !os.IsNotExist(err) {
			// It exists.. so
			fmt.Println("Attempting to rm -R " + abf + "...")
			cRun := exec.Command("rm", "-R", abf)
			if err := cRun.Run(); err != nil {
				log.Println("Error:", err)
			}
		}
		fmt.Println("Uninstall complete.")
	},
}

func init() {
	rootCmd.AddCommand(uninstallCmd)

	// Here you will define your flags and configuration settings.

	// Cobra supports Persistent Flags which will work for this command
	// and all subcommands, e.g.:
	// freshstartCmd.PersistentFlags().String("foo", "", "A help for foo")

	// Cobra supports local flags which will only run when this command
	// is called directly, e.g.:
	// freshstartCmd.Flags().BoolP("toggle", "t", false, "Help message for toggle")
}
