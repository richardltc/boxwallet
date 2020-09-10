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
	"errors"
	"fmt"
	// gwc "github.com/richardltc/gwcommon"
	"github.com/spf13/cobra"
	"log"
	be "richardmace.co.uk/boxwallet/cmd/cli/cmd/bend"
)

// startCmd represents the start command
var startCmd = &cobra.Command{
	Use:   "start",
	Short: "Starts you chosen coins daemon server",
	Long:  ``,
	Run: func(cmd *cobra.Command, args []string) {
		// Lets load our config file first, to see if the user has made their coin choice...
		cliConf, err := be.GetConfigStruct("", true)
		if err != nil {
			log.Fatal("Unable to determine coin type. Please run " + be.CAppFilename + " coin" + err.Error())
			//log.Fatal("Unable to GetCLIConfStruct " + err.Error())
		}

		sCoinDaemonName, err := be.GetCoinDaemonFilename(be.APPTCLI)
		if err != nil {
			log.Fatal("Unable to GetCoinDaemonFilename " + err.Error())
		}

		if cliConf.ServerIP != "127.0.0.1" {
			log.Fatal("The start command can only be run on the same machine that's running the " + sCoinDaemonName + " wallet")
		}

		switch cliConf.ProjectType {
		case be.PTDivi:
			// Add the addnodes if required...
			log.Println("Checking for addnodes...")
			exist, err := be.AddNodesDiviAlreadyExist()
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
		case be.PTPhore:
		case be.PTTrezarcoin:
		default:
			err = errors.New("unable to determine ProjectType")
		}

		// Start the coin daemon server if required...
		if err := be.RunCoinDaemon(true); err != nil {
			log.Fatalf("failed to run "+sCoinDaemonName+": %v", err)
		}

		//runDashNow := false
		//prompt := &survey.Confirm{
		//	Message: "Run Dash now?",
		//}
		//survey.AskOne(prompt, &runDashNow)

		sAppFileCLIName, err := be.GetAppFileName()
		if err != nil {
			log.Fatal("Unable to GetAppFileCLIName " + err.Error())
		}
		abf, err := be.GetAppsBinFolder()
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
