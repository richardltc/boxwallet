/*
Copyright © 2021 NAME HERE <EMAIL ADDRESS>

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
	"github.com/AlecAivazis/survey/v2"
	"log"
	be "richardmace.co.uk/boxwallet/cmd/cli/cmd/bend"

	"github.com/spf13/cobra"
)

// resyncCmd represents the resync command
var resyncCmd = &cobra.Command{
	Use:   "resync",
	Short: "Performs a resync of the complete blockchain",
	Long:  ``,
	Run: func(cmd *cobra.Command, args []string) {
		bwConf, err := be.GetConfigStruct("", true)
		if err != nil {
			log.Fatal("Unable to GetCLIConfStruct " + err.Error())
		}

		cn, err := be.GetCoinName(be.APPTCLI)
		if err != nil {
			log.Fatal("Unable to GetCoinName " + err.Error())
		}

		ans := false
		prompt := &survey.Confirm{
			Message: `Are you sure? Perform a resync on your ` + cn + ` wallet?:`,
		}
		if err := survey.AskOne(prompt, &ans); err != nil {
			log.Fatal("Error using survey: " + err.Error())
		}
		if !ans {
			log.Fatal("reindex not attempted.")
		}
		if err := be.WalletFix(be.WFTReSync, bwConf.ProjectType); err != nil {
			log.Fatal("Unable to perform resync: " + err.Error())
		}

		fmt.Println("Your " + cn + " wallet is now syncing again. Please use ./boxwallet dash to view")
	},
}

func init() {
	walletCmd.AddCommand(resyncCmd)

	// Here you will define your flags and configuration settings.

	// Cobra supports Persistent Flags which will work for this command
	// and all subcommands, e.g.:
	// resyncCmd.PersistentFlags().String("foo", "", "A help for foo")

	// Cobra supports local flags which will only run when this command
	// is called directly, e.g.:
	// resyncCmd.Flags().BoolP("toggle", "t", false, "Help message for toggle")
}
