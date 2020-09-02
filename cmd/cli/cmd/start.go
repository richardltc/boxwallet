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
	gwc "github.com/richardltc/gwcommon"
	"github.com/spf13/cobra"
	"log"
	be "richardmace.co.uk/boxdivi/cmd/cli/cmd/bend"
)

// startCmd represents the start command
var startCmd = &cobra.Command{
	Use:   "start",
	Short: "Starts the " + sCoinDName + " daemon server",
	Long:  ``,
	Run: func(cmd *cobra.Command, args []string) {
		// Check to make sure that we are running on the same machine as the coin daemon e.g. divid
		cliConf, err := gwc.GetCLIConfStruct()
		if err != nil {
			log.Fatal("Unable to GetCLIConfStruct " + err.Error())
		}
		sCoinDaemonName, err := gwc.GetCoinDaemonFilename(gwc.APPTCLI)
		if err != nil {
			log.Fatal("Unable to GetCoinDaemonFilename " + err.Error())
		}

		if cliConf.ServerIP != "127.0.0.1" {
			log.Fatal("The start command can only be run on the same machine that's running the " + sCoinDaemonName + " wallet")
		}

		// Add the addnodes if required...
		log.Println("Checking for addnodes...")
		exist, err := be.AddNodesAlreadyExist()
		if err != nil {
			log.Fatalf("unable to detect whether addnodes already exist: %v", err)
		}
		if exist {
			log.Println("addnodes already exist...")
		} else {
			log.Println("addnodes are missing, so attempting to add...")
			if err := be.AddAddNodesIfRequired(); err != nil {
				log.Fatalf("failed to add addnodes: %v", err)
			}
			log.Println("addnodes added...")
		}

		// Start the coin daemon server if required...
		if err := be.RunCoinDaemon(true); err != nil {
			log.Fatalf("failed to run "+sCoinDName+": %v", err)
		}

		//runDashNow := false
		//prompt := &survey.Confirm{
		//	Message: "Run Dash now?",
		//}
		//survey.AskOne(prompt, &runDashNow)

		sAppFileCLIName, err := gwc.GetAppFileName(gwc.APPTCLI)
		if err != nil {
			log.Fatal("Unable to GetAppFileCLIName " + err.Error())
		}
		abf, err := gwc.GetAppsBinFolder(gwc.APPTCLI)
		if err != nil {
			log.Fatal("Unable to GetAppsBinFolder " + err.Error())
		}
		fmt.Println("Now, simply run " + abf + sAppFileCLIName + " dash\n\n")
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
