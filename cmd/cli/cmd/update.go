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
	"log"

	gwc "github.com/richardltc/gwcommon"
	"github.com/spf13/cobra"
)

// updateCmd represents the update command
var updateCmd = &cobra.Command{
	Use:   "update",
	Short: "You can update " + sAppCLIName + " to the latest version by running " + sAppUpdaterFile,
	Long:  ``,
	Run: func(cmd *cobra.Command, args []string) {
		sAppName, err := gwc.GetAppName(gwc.APPTCLI)
		if err != nil {
			log.Fatal("Unable to GetAppName " + err.Error())
		}
		abf, err := gwc.GetAppsBinFolder(gwc.APPTCLI)
		if err != nil {
			log.Fatal("Unable to GetAppsBinFolder " + err.Error())
		}

		log.Fatal(sAppName + ` can be updated to the latest version by running "./` + sAppUpdaterFile + `" from within the ` + abf + " folder.")
	},
}

func init() {
	rootCmd.AddCommand(updateCmd)

	// Here you will define your flags and configuration settings.

	// Cobra supports Persistent Flags which will work for this command
	// and all subcommands, e.g.:
	// updateCmd.PersistentFlags().String("foo", "", "A help for foo")

	// Cobra supports local flags which will only run when this command
	// is called directly, e.g.:
	// updateCmd.Flags().BoolP("toggle", "t", false, "Help message for toggle")
}
