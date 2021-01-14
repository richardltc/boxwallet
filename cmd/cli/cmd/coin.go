/*
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
	"github.com/AlecAivazis/survey/v2"
	"log"
	"os"
	be "richardmace.co.uk/boxwallet/cmd/cli/cmd/bend"
	"runtime"

	"github.com/artdarek/go-unzip"
	"github.com/mholt/archiver/v3"
	"github.com/spf13/cobra"
)

// coinCmd represents the coin command
var coinCmd = &cobra.Command{
	Use:   "coin",
	Short: "Select which coin you wish to work with",
	Long:  ``,
	Run: func(cmd *cobra.Command, args []string) {
		fmt.Println("  ____          __          __   _ _      _   \n |  _ \\         \\ \\        / /  | | |    | |  \n | |_) | _____  _\\ \\  /\\  / /_ _| | | ___| |_ \n |  _ < / _ \\ \\/ /\\ \\/  \\/ / _` | | |/ _ \\ __|\n | |_) | (_) >  <  \\  /\\  / (_| | | |  __/ |_ \n |____/ \\___/_/\\_\\  \\/  \\/ \\__,_|_|_|\\___|\\__| v" + be.CBWAppVersion + "\n                                              \n                                               ")
		coin := ""
		lf, _ := be.GetAppWorkingFolder()
		lf = lf + be.CAppLogfile
		be.AddToLog(lf, "coin command invoked", false)
		prompt := &survey.Select{
			Message: "Please choose your preferred coin:",
			Options: []string{be.CCoinNameDivi,
				be.CCoinNameDeVault,
				be.CCoinNameFeathercoin,
				be.CCoinNameGroestlcoin,
				be.CCoinNamePhore,
				be.CCoinNamePIVX,
				be.CCoinNameRapids,
				be.CCoinNameReddCoin,
				be.CCoinNameScala,
				be.CCoinNameTrezarcoin,
				be.CCoinNameVertcoin},
		}
		survey.AskOne(prompt, &coin)
		cliConf := be.ConfStruct{}
		cliConf.ServerIP = "127.0.0.1"

		switch coin {
		case be.CCoinNameDeVault:
			be.AddToLog(lf, be.CCoinNameDeVault+" selected", false)
			cliConf.ProjectType = be.PTDeVault
			cliConf.Port = be.CDeVaultRPCPort
		case be.CCoinNameDivi:
			be.AddToLog(lf, be.CCoinNameDivi+" selected", false)
			cliConf.ProjectType = be.PTDivi
			cliConf.Port = be.CDiviRPCPort
		case be.CCoinNameFeathercoin:
			be.AddToLog(lf, be.CCoinNameFeathercoin+" selected", false)
			cliConf.ProjectType = be.PTFeathercoin
			cliConf.Port = be.CFeathercoinRPCPort
		case be.CCoinNameGroestlcoin:
			be.AddToLog(lf, be.CCoinNameGroestlcoin+" selected", false)
			cliConf.ProjectType = be.PTGroestlcoin
			cliConf.Port = be.CGroestlcoinRPCPort
		case be.CCoinNamePhore:
			be.AddToLog(lf, be.CCoinNamePhore+" selected", false)
			cliConf.ProjectType = be.PTPhore
			cliConf.Port = be.CPhoreRPCPort
		case be.CCoinNamePIVX:
			be.AddToLog(lf, be.CCoinNamePIVX+" selected", false)
			cliConf.ProjectType = be.PTPIVX
			cliConf.Port = be.CPIVXRPCPort
		case be.CCoinNameRapids:
			be.AddToLog(lf, be.CCoinNameRapids+" selected", false)
			cliConf.ProjectType = be.PTRapids
			cliConf.Port = be.CRapidsRPCPort
		case be.CCoinNameReddCoin:
			be.AddToLog(lf, be.CCoinNameReddCoin+" selected", false)
			cliConf.ProjectType = be.PTReddCoin
			cliConf.Port = be.CReddCoinRPCPort
		case be.CCoinNameScala:
			be.AddToLog(lf, be.CCoinNameScala+" selected", false)
			cliConf.ProjectType = be.PTScala
			cliConf.Port = be.CScalaRPCPort
		case be.CCoinNameTrezarcoin:
			be.AddToLog(lf, be.CCoinNameTrezarcoin+" selected", false)
			cliConf.ProjectType = be.PTTrezarcoin
			cliConf.Port = be.CTrezarcoinRPCPort
		case be.CCoinNameVertcoin:
			be.AddToLog(lf, be.CCoinNameVertcoin+" selected", false)
			cliConf.ProjectType = be.PTVertcoin
			cliConf.Port = be.CVertcoinRPCPort
		default:
			log.Fatal("Unable to determine coin choice")
		}

		// Create the App Working folder if required...
		awf, _ := be.GetAppWorkingFolder()
		if err := os.MkdirAll(awf, os.ModePerm); err != nil {
			be.AddToLog(lf, "unable to make directory: "+err.Error(), false)
			log.Fatal("unable to make directory: ", err)
		}

		if err := be.SetConfigStruct("", cliConf); err != nil {
			log.Fatal("Unable to write to config file: ", err)
		}
		sCoinName, err := be.GetCoinName(be.APPTCLI)
		if err != nil {
			log.Fatal("Unable to GetCoinName " + err.Error())
		}

		rpcu, rpcpw, err := be.PopulateDaemonConfFile()
		if err != nil {
			log.Fatal(err)
		}
		// ...because it's possible that the conf file for this coin has already been created, we need to store the
		// returned user and password so, effectively, will either be storing the existing info, or
		// the freshly generated info.
		cliConf.RPCuser = rpcu
		cliConf.RPCpassword = rpcpw
		err = be.SetConfigStruct("", cliConf)
		if err != nil {
			log.Fatal(err)
		}

		be.AddToLog(lf, "checking to see if all required project files exist... ", false)
		b, err := be.AllProjectBinaryFilesExists()
		if err != nil {
			be.AddToLog(lf, "Err: "+err.Error(), false)
			log.Fatal(err)
		}
		if !b {
			be.AddToLog(lf, "The "+sCoinName+" CLI bin files haven't been installed yet. So installing them now...", true)
			if err := doRequiredFiles(); err != nil {
				be.AddToLog(lf, "unable to complete func doRequiredFiles: "+err.Error(), false)
				log.Fatal(err)
			}
		} else {
			be.AddToLog(lf, "The "+sCoinName+" CLI bin files have already been installed.", true)
		}
		fmt.Println("\nAll done!")
		fmt.Println("\nYou can now run './boxwallet start' and then './boxwallet dash' to view your " + sCoinName + " Dashboard")
		fmt.Println("\n\nThank you for using " + be.CAppName + " to run your " + sCoinName + " wallet/node.")
		fmt.Println(be.CAppName + " is FREE to use, and if you'd like to send a tip, please feel free to at the following " + sCoinName + " address below:")

		// Display tip message.
		switch cliConf.ProjectType {
		case be.PTDeVault:
			fmt.Println("\nDVT: devault:qp7w4pnm774c0uwch8ty6tj7sw86hze9ps4sqrwcue")
		case be.PTDivi:
			fmt.Println("\nDIVI: DGvhjUXznuDyALk9zX4Y3ko4QQTmRhF7jZ")
		case be.PTFeathercoin:
			fmt.Println("\nFTC: 6yWAnPUcgWGXnXAM9u4faDVmfJwxKphcLf")
		case be.PTGroestlcoin:
			fmt.Println("\nGRS: 3HBqpZ1JH125FmW52GYjoBpNEAwyxjL9t9")
		case be.PTPhore:
			fmt.Println("\nPHR: PKFcy7UTEWegnAq7Wci8Aj76bQyHMottF8")
		case be.PTPIVX:
			fmt.Println("\nPIVX: DFHmj4dExVC24eWoRKmQJDx57r4svGVs3J")
		case be.PTRapids:
			fmt.Println("\nRPD: RvxCvM2VWVKq2iSLNoAmzdqH4eF9bhvn6k")
		case be.PTReddCoin:
			fmt.Println("\nRDD: RtH6nZvmnstUsy5w5cmdwTrarbTPm6zyrC")
		case be.PTScala:
			fmt.Println("\nXLA: Svkhh1KJ7qSPEtoAzAuriLUzVSseezcs2GS21bAL5rWEYD2iBykLvHUaMaQEcrF1pPfTkfEbWGsXz4zfXJWmQvat2Q2EHhS1e")
		case be.PTTrezarcoin:
			fmt.Println("\nTZC: TnkHScr6iTcfK11GDPFjNgJ7V3GZtHEy9V")
		case be.PTVertcoin:
			fmt.Println("\nVTC: vtc1q72j7fre83q8a7feppj28qkzfdt5vkcjr7xd74p")
		default:
			fmt.Println("\nDIVI: DGvhjUXznuDyALk9zX4Y3ko4QQTmRhF7jZ")
		}
	},
}

// doRequiredFiles - Download and install required files.
func doRequiredFiles() error {
	var filePath, fileURL string
	abf, err := be.GetAppWorkingFolder()
	lf, _ := be.GetAppWorkingFolder()
	lf = lf + be.CAppLogfile

	//ex, err := os.Executable()
	//if err != nil {
	//	return fmt.Errorf("Unable to retrieve running binary: %v ", err)
	//}
	//abf := be.AddTrailingSlash(filepath.Dir(ex))

	bwconf, err := be.GetConfigStruct("", true)
	if err != nil {
		return fmt.Errorf("Unable to get CLIConfigStruct: %v ", err)
	}
	switch bwconf.ProjectType {
	case be.PTDeVault:
		if runtime.GOOS == "windows" {
			filePath = abf + be.CDFDeVaultWindows
			fileURL = be.CDownloadURLDeVault + be.CDFDeVaultWindows
		} else if runtime.GOARCH == "arm" {
			filePath = abf + be.CDFDeVaultRPi
			fileURL = be.CDownloadURLDeVault + be.CDFDeVaultRPi
		} else {
			filePath = abf + be.CDFDeVaultLinux
			fileURL = be.CDownloadURLDeVault + be.CDFDeVaultLinux
		}
	case be.PTDivi:
		if runtime.GOOS == "windows" {
			filePath = abf + be.CDFDiviWindows
			fileURL = be.CDownloadURLDivi + be.CDFDiviWindows
		} else if runtime.GOARCH == "arm" {
			filePath = abf + be.CDFDiviRPi
			fileURL = be.CDownloadURLDivi + be.CDFDiviRPi
		} else {
			filePath = abf + be.CDFDiviLinux
			fileURL = be.CDownloadURLDivi + be.CDFDiviLinux
		}
	case be.PTFeathercoin:
		if runtime.GOOS == "windows" {
			filePath = abf + be.CDFFeathercoinWindows
			fileURL = be.CDownloadURLFeathercoin + be.CDFFeathercoinWindows
		} else if runtime.GOARCH == "arm" {
			return fmt.Errorf("ARM is not supported for this build: %v ", err)
		} else {
			filePath = abf + be.CDFFeathercoinLinux
			fileURL = be.CDownloadURLFeathercoin + be.CDFFeathercoinLinux
		}
	case be.PTGroestlcoin:
		if runtime.GOOS == "windows" {
			filePath = abf + be.CDFGroestlcoinWindows
			fileURL = be.CDownloadURLGroestlcoin + be.CDFGroestlcoinWindows
		} else if runtime.GOARCH == "arm" {
			filePath = abf + be.CDFGroestlcoinRPi
			fileURL = be.CDownloadURLGroestlcoin + be.CDFGroestlcoinRPi
		} else {
			filePath = abf + be.CDFGroestlcoinLinux
			fileURL = be.CDownloadURLGroestlcoin + be.CDFGroestlcoinLinux
		}
	case be.PTPhore:
		if runtime.GOOS == "windows" {
			filePath = abf + be.CDFPhoreWindows
			fileURL = be.CDownloadURLPhore + be.CDFPhoreWindows
		} else if runtime.GOARCH == "arm" {
			filePath = abf + be.CDFPhoreRPi
			fileURL = be.CDownloadURLPhore + be.CDFPhoreRPi
		} else {
			filePath = abf + be.CDFPhoreLinux
			fileURL = be.CDownloadURLPhore + be.CDFPhoreLinux
		}
	case be.PTPIVX:
		if runtime.GOOS == "windows" {
			filePath = abf + be.CDFPIVXFileWindows
			fileURL = be.CDownloadURLPIVX + be.CDFPIVXFileWindows
		} else if runtime.GOARCH == "arm" {
			filePath = abf + be.CDFPIVXFileRPi
			fileURL = be.CDownloadURLPIVX + be.CDFPIVXFileRPi
		} else {
			filePath = abf + be.CDFPIVXFileLinux
			fileURL = be.CDownloadURLPIVX + be.CDFPIVXFileLinux
		}
	case be.PTRapids:
		if runtime.GOOS == "windows" {
			filePath = abf + be.CDFRapidsFileWindows
			fileURL = be.CDownloadURLRapids + be.CDFRapidsFileWindows
		} else if runtime.GOARCH == "arm" {
			filePath = abf + be.CDFRapidsFileRPi
			fileURL = be.CDownloadURLRapids + be.CDFRapidsFileRPi
		} else {
			filePath = abf + be.CDFRapidsFileLinux
			//filePath2 = abf + be.CDFRapidsFileLinuxDaemon
			fileURL = be.CDownloadURLRapids + be.CDFRapidsFileLinux
			//fileURL2 = be.CDownloadURLRapids + be.CDFRapidsFileLinuxDaemon
		}
	case be.PTReddCoin:
		if runtime.GOOS == "windows" {
			filePath = abf + be.CDFReddCoinWindows
			fileURL = be.CDownloadURLReddCoinGen + be.CDFReddCoinWindows
		} else if runtime.GOARCH == "arm" {
			filePath = abf + be.CDFReddCoinRPi
			fileURL = be.CDownloadURLReddCoinArm
		} else {
			filePath = abf + be.CDFReddCoinLinux
			fileURL = be.CDownloadURLReddCoinGen + be.CDFReddCoinLinux
		}
	case be.PTScala:
		if runtime.GOOS == "windows" {
			filePath = abf + be.CDFScalaWindows
			fileURL = be.CDownloadURLScala + be.CDFScalaWindows
		} else if runtime.GOARCH == "arm" {
			filePath = abf + be.CDFScalaRPi
			fileURL = be.CDownloadURLScala + be.CDFScalaRPi
		} else {
			filePath = abf + be.CDFScalaLinux
			fileURL = be.CDownloadURLScala + be.CDFScalaLinux
		}
	case be.PTTrezarcoin:
		be.AddToLog(lf, "TZC detected...", false)
		if runtime.GOOS == "windows" {
			be.AddToLog(lf, "windows detected...", false)
			filePath = abf + be.CDFTrezarcoinWindows
			fileURL = be.CDownloadURLTC + be.CDFTrezarcoinWindows
		} else if runtime.GOARCH == "arm" {
			be.AddToLog(lf, "arm detected...", false)
			filePath = abf + be.CDFTrezarcoinRPi
			fileURL = be.CDownloadURLTC + be.CDFTrezarcoinRPi
		} else {
			be.AddToLog(lf, "linux detected...", false)
			filePath = abf + be.CDFTrezarcoinLinux
			fileURL = be.CDownloadURLTC + be.CDFTrezarcoinLinux
		}
	case be.PTVertcoin:
		if runtime.GOOS == "windows" {
			filePath = abf + be.CDFVertcoinWindows
			fileURL = be.CDownloadURLVertcoin + be.CDFVertcoinWindows
		} else if runtime.GOARCH == "arm" {
			return fmt.Errorf("ARM is not supported for this build: %v ", err)
		} else {
			filePath = abf + be.CDFVertcoinLinux
			fileURL = be.CDownloadURLVertcoin + be.CDFVertcoinLinux
		}
	default:
		err = errors.New("unable to determine ProjectType")
	}
	if err != nil {
		return fmt.Errorf("error - %v", err)
	}

	be.AddToLog(lf, "filePath="+filePath, false)
	be.AddToLog(lf, "fileURL="+fileURL, false)
	be.AddToLog(lf, "Downloading required files...", true)

	if err := be.DownloadFile(filePath, fileURL); err != nil {
		return fmt.Errorf("unable to download file: %v - %v", filePath+fileURL, err)
	}
	defer os.Remove(filePath)

	r, err := os.Open(filePath)
	if err != nil {
		return fmt.Errorf("unable to open file: %v - %v", filePath, err)
	}

	// Now, decompress the files...
	be.AddToLog(lf, "decompressing files...", true)
	switch bwconf.ProjectType {
	case be.PTDeVault:
		if runtime.GOOS == "windows" {
			//_, err = be.UnZip(filePath, "tmp")
			_, err = be.UnZip(filePath, abf)
			if err != nil {
				return fmt.Errorf("unable to unzip file: %v - %v", filePath, err)
			}
			defer os.RemoveAll(abf)
		} else if runtime.GOARCH == "arm" {
			//err = be.ExtractTarGz(r)
			err = archiver.Unarchive(filePath, abf)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll(abf + be.CDeVaultExtractedDirLinux)
		} else {
			err = archiver.Unarchive(filePath, abf)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll(abf + be.CDeVaultExtractedDirLinux)
		}
	case be.PTDivi:
		if runtime.GOOS == "windows" {
			_, err = be.UnZip(filePath, abf)
			if err != nil {
				return fmt.Errorf("unable to unzip file: %v - %v", filePath, err)
			}
			defer os.RemoveAll(abf)
		} else if runtime.GOARCH == "arm" {
			//err = be.ExtractTarGz(r)
			err = archiver.Unarchive(filePath, abf)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll(abf + be.CDiviExtractedDirLinux)
		} else {
			//err = be.ExtractTarGz(r)
			err = archiver.Unarchive(filePath, abf)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll(abf + be.CDiviExtractedDirLinux)
		}
	case be.PTFeathercoin:
		if runtime.GOOS == "windows" {
			_, err = be.UnZip(filePath, abf)
			if err != nil {
				return fmt.Errorf("unable to unzip file: %v - %v", filePath, err)
			}
			defer os.RemoveAll(abf)
		} else if runtime.GOARCH == "arm" {
			//err = be.ExtractTarGz(r)
			err = archiver.Unarchive(filePath, abf)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll(abf + be.CFeathercoinExtractedDirLinux)
		} else {
			//err = be.ExtractTarGz(r)
			err = archiver.Unarchive(filePath, abf)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll(abf + be.CFeathercoinExtractedDirLinux)
		}
	case be.PTGroestlcoin:
		if runtime.GOOS == "windows" {
			_, err = be.UnZip(filePath, abf)
			if err != nil {
				return fmt.Errorf("unable to unzip file: %v - %v", filePath, err)
			}
			defer os.RemoveAll(abf)
		} else if runtime.GOARCH == "arm" {
			//err = be.ExtractTarGz(r)
			err = archiver.Unarchive(filePath, abf)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll(abf + be.CGroestlcoinExtractedDirLinux)
		} else {
			//err = be.ExtractTarGz(r)
			err = archiver.Unarchive(filePath, abf)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll(abf + be.CGroestlcoinExtractedDirLinux)
		}
	case be.PTPhore:
		if runtime.GOOS == "windows" {
			_, err = be.UnZip(filePath, abf)
			if err != nil {
				return fmt.Errorf("unable to unzip file: %v - %v", filePath, err)
			}
			defer os.RemoveAll(abf)
		} else if runtime.GOARCH == "arm" {
			//err = be.ExtractTarGz(r)
			err = archiver.Unarchive(filePath, abf)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll(abf + be.CPhoreExtractedDirLinux)
		} else {
			//err = be.ExtractTarGz(r)
			err = archiver.Unarchive(filePath, abf)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll(abf + be.CPhoreExtractedDirLinux)
		}
	case be.PTPIVX:
		if runtime.GOOS == "windows" {
			_, err = be.UnZip(filePath, abf)
			if err != nil {
				return fmt.Errorf("unable to unzip file: %v - %v", filePath, err)
			}
			defer os.RemoveAll(abf)
		} else if runtime.GOARCH == "arm" {
			//err = be.ExtractTarGz(r)
			err = archiver.Unarchive(filePath, abf)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll(abf + be.CPIVXExtractedDirArm)
		} else {
			//err = be.ExtractTarGz(r)
			err = archiver.Unarchive(filePath, abf)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll(abf + be.CPIVXExtractedDirLinux)
		}
	case be.PTRapids:
		if runtime.GOOS == "windows" {
			_, err = be.UnZip(filePath, abf)
			if err != nil {
				return fmt.Errorf("unable to unzip file: %v - %v", filePath, err)
			}
			defer os.RemoveAll(abf)
		} else if runtime.GOARCH == "arm" {
			//err = be.ExtractTarGz(r)
			err = archiver.Unarchive(filePath, abf)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll(abf + be.CRapidsExtractedDirLinux)
		} else {
			// First the normal file...
			err = archiver.Unarchive(filePath, abf)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll(abf + be.CRapidsExtractedDirLinux)
		}
	case be.PTReddCoin:
		if runtime.GOOS == "windows" {
			//_, err = be.UnZip(filePath, "tmp")
			_, err = be.UnZip(filePath, abf)
			if err != nil {
				return fmt.Errorf("unable to unzip file: %v - %v", filePath, err)
			}
			defer os.RemoveAll(abf)
		} else if runtime.GOARCH == "arm" {
			//err = be.ExtractTarGz(r)
			err = archiver.Unarchive(filePath, abf)
			if err != nil {
				return fmt.Errorf("unable to unarchive file: %v - %v", r, err)
			}
			defer os.RemoveAll(abf + be.CReddCoinExtractedDirLinux)
		} else {
			err = archiver.Unarchive(filePath, abf)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll(abf + be.CReddCoinExtractedDirLinux)
		}
	case be.PTScala:
		if runtime.GOOS == "windows" {
			_, err = be.UnZip(filePath, abf)
			if err != nil {
				return fmt.Errorf("unable to unzip file: %v - %v", filePath, err)
			}
			defer os.RemoveAll(abf)
		} else if runtime.GOARCH == "arm" {
			//err = be.ExtractTarGz(r)
			err = archiver.Unarchive(filePath, abf)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll(abf + be.CScalaExtractedDirLinux)
		} else {
			uz := unzip.New(filePath, abf)
			err := uz.Extract()
			if err != nil {
				return fmt.Errorf("unable to unzip file: %v - %v", filePath, err)
			}
			defer os.RemoveAll("tmp")
		}
	case be.PTTrezarcoin:
		if runtime.GOOS == "windows" {
			_, err = be.UnZip(filePath, abf)
			if err != nil {
				return fmt.Errorf("unable to unzip file: %v - %v", filePath, err)
			}
			defer os.RemoveAll(abf)
		} else if runtime.GOARCH == "arm" {
			//err = be.ExtractTarGz(r)
			err = archiver.Unarchive(filePath, abf)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll(abf + be.CTrezarcoinRPiExtractedDir)
		} else {
			//err = be.ExtractTarGz(r)
			err = archiver.Unarchive(filePath, abf)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll(abf + be.CTrezarcoinLinuxExtractedDir)
		}
	case be.PTVertcoin:
		if runtime.GOOS == "windows" {
			_, err = be.UnZip(filePath, "tmp")
			if err != nil {
				return fmt.Errorf("unable to unzip file: %v - %v", filePath, err)
			}
			defer os.RemoveAll("tmp")
		} else if runtime.GOARCH == "arm" {
			//err = be.ExtractTarGz(r)
			err = archiver.Unarchive(filePath, abf)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll(abf + be.CVertcoinExtractedDirLinux)
		} else {
			uz := unzip.New(filePath, abf)
			err := uz.Extract()
			if err != nil {
				return fmt.Errorf("unable to unzip file: %v - %v", filePath, err)
			}
			defer os.RemoveAll("tmp")
		}
	default:
		err = errors.New("unable to determine ProjectType")
	}

	if err := be.AddToLog(lf, "Installing files...", true); err != nil {
		return fmt.Errorf("unable to add to log file: %v", err)
	}

	// Copy files to correct location
	var srcPath, srcPathD, srcFileCLI, srcFileD, srcFileTX, srcPathSap, srcFileSap1, srcFileSap2 string

	switch bwconf.ProjectType {
	case be.PTDeVault:
		if err := be.AddToLog(lf, "DeVault detected...", false); err != nil {
			return fmt.Errorf("unable to add to log file: %v", err)
		}
		switch runtime.GOOS {
		case "windows":
			srcPath = abf + be.CDeVaultExtractedDirWin + "bin\\"
			srcFileCLI = be.CDeVaultCliFileWin
			srcFileD = be.CDeVaultDFileWin
			srcFileTX = be.CDeVaultTxFileWin
			//srcFileBWCLI = be.CAppFilenameWin
		case "linux":
			switch runtime.GOARCH {
			case "arm":
				if err := be.AddToLog(lf, "linux arm detected.", false); err != nil {
					return fmt.Errorf("unable to add to log file: %v", err)
				}
				srcPath = abf + be.CDeVaultExtractedDirLinux + "bin/"
				srcFileCLI = be.CDeVaultCliFile
				srcFileD = be.CDeVaultDFile
				srcFileTX = be.CDeVaultTxFile
			//srcFileBWCLI = be.CAppFilename
			case "amd64":
				if err := be.AddToLog(lf, "linux amd64 detected.", false); err != nil {
					return fmt.Errorf("unable to add to log file: %v", err)
				}
				srcPath = abf + be.CDeVaultExtractedDirLinux + "bin/"
				srcFileCLI = be.CDeVaultCliFile
				srcFileD = be.CDeVaultDFile
				srcFileTX = be.CDeVaultTxFile
			//srcFileBWCLI = be.CAppFilename
			default:
				err = errors.New("unable to determine runtime.GOARCH " + runtime.GOARCH)
			}
		default:
			err = errors.New("unable to determine runtime.GOOS")
		}
	case be.PTDivi:
		if err := be.AddToLog(lf, "DIVI detected...", false); err != nil {
			return fmt.Errorf("unable to add to log file: %v", err)
		}
		switch runtime.GOOS {
		case "windows":
			srcPath = abf + be.CDiviExtractedDirWindows + "bin\\"
			srcFileCLI = be.CDiviCliFileWin
			srcFileD = be.CDiviDFileWin
			srcFileTX = be.CDiviTxFileWin
			//srcFileBWCLI = be.CAppFilenameWin
		case "linux":
			switch runtime.GOARCH {
			case "arm":
				if err := be.AddToLog(lf, "linux arm detected.", false); err != nil {
					return fmt.Errorf("unable to add to log file: %v", err)
				}
				srcPath = abf + be.CDiviExtractedDirLinux + "bin/"
				srcFileCLI = be.CDiviCliFile
				srcFileD = be.CDiviDFile
				srcFileTX = be.CDiviTxFile
			//srcFileBWCLI = be.CAppFilename
			case "amd64":
				if err := be.AddToLog(lf, "linux amd64 detected.", false); err != nil {
					return fmt.Errorf("unable to add to log file: %v", err)
				}
				srcPath = abf + be.CDiviExtractedDirLinux + "bin/"
				srcFileCLI = be.CDiviCliFile
				srcFileD = be.CDiviDFile
				srcFileTX = be.CDiviTxFile
			//srcFileBWCLI = be.CAppFilename
			default:
				err = errors.New("unable to determine runtime.GOARCH " + runtime.GOARCH)
			}
		default:
			err = errors.New("unable to determine runtime.GOOS")
		}
	case be.PTFeathercoin:
		if err := be.AddToLog(lf, "Feathercoin detected...", false); err != nil {
			return fmt.Errorf("unable to add to log file: %v", err)
		}
		switch runtime.GOOS {
		case "windows":
			srcPath = abf + be.CFeathercoinExtractedDirLinux
			srcFileCLI = be.CFeathercoinCliFileWin
			srcFileD = be.CFeathercoinDFileWin
			srcFileTX = be.CFeathercoinTxFileWin
			//srcFileBWCLI = be.CAppFilenameWin
		case "linux":
			switch runtime.GOARCH {
			case "arm":
				if err := be.AddToLog(lf, "linux arm detected.", false); err != nil {
					return fmt.Errorf("unable to add to log file: %v", err)
				}
				srcPath = abf + be.CFeathercoinExtractedDirLinux
				srcFileCLI = be.CFeathercoinCliFile
				srcFileD = be.CFeathercoinDFile
				srcFileTX = be.CFeathercoinTxFile
			//srcFileBWCLI = be.CAppFilename
			case "amd64":
				if err := be.AddToLog(lf, "linux amd64 detected.", false); err != nil {
					return fmt.Errorf("unable to add to log file: %v", err)
				}
				srcPath = abf + be.CFeathercoinExtractedDirLinux
				srcFileCLI = be.CFeathercoinCliFile
				srcFileD = be.CFeathercoinDFile
				srcFileTX = be.CFeathercoinTxFile
			//srcFileBWCLI = be.CAppFilename
			default:
				err = errors.New("unable to determine runtime.GOARCH " + runtime.GOARCH)
			}
		default:
			err = errors.New("unable to determine runtime.GOOS")
		}
	case be.PTGroestlcoin:
		if err := be.AddToLog(lf, "Groestlcoin detected...", false); err != nil {
			return fmt.Errorf("unable to add to log file: %v", err)
		}
		switch runtime.GOOS {
		case "windows":
			srcPath = abf + be.CGroestlcoinExtractedDirWindows + "bin\\"
			srcFileCLI = be.CGroestlcoinCliFileWin
			srcFileD = be.CGroestlcoinDFileWin
			srcFileTX = be.CGroestlcoinTxFileWin
			//srcFileBWCLI = be.CAppFilenameWin
		case "linux":
			switch runtime.GOARCH {
			case "arm":
				if err := be.AddToLog(lf, "linux arm detected.", false); err != nil {
					return fmt.Errorf("unable to add to log file: %v", err)
				}
				srcPath = abf + be.CGroestlcoinExtractedDirLinux + "bin/"
				srcFileCLI = be.CGroestlcoinCliFile
				srcFileD = be.CGroestlcoinDFile
				srcFileTX = be.CGroestlcoinTxFile
			//srcFileBWCLI = be.CAppFilename
			case "amd64":
				if err := be.AddToLog(lf, "linux amd64 detected.", false); err != nil {
					return fmt.Errorf("unable to add to log file: %v", err)
				}
				srcPath = abf + be.CGroestlcoinExtractedDirLinux + "bin/"
				srcFileCLI = be.CGroestlcoinCliFile
				srcFileD = be.CGroestlcoinDFile
				srcFileTX = be.CGroestlcoinTxFile
			//srcFileBWCLI = be.CAppFilename
			default:
				err = errors.New("unable to determine runtime.GOARCH " + runtime.GOARCH)
			}
		default:
			err = errors.New("unable to determine runtime.GOOS")
		}
	case be.PTPhore:
		if err := be.AddToLog(lf, "Phore detected...", false); err != nil {
			return fmt.Errorf("unable to add to log file: %v", err)
		}
		switch runtime.GOOS {
		case "windows":
			srcPath = abf + be.CPhoreExtractedDirLinux + "bin\\"
			srcFileCLI = be.CPhoreCliFileWin
			srcFileD = be.CPhoreDFileWin
			srcFileTX = be.CPhoreTxFileWin
			//srcFileBWCLI = be.CAppFilenameWin
		case "linux":
			switch runtime.GOARCH {
			case "arm":
				if err := be.AddToLog(lf, "linux arm detected.", false); err != nil {
					return fmt.Errorf("unable to add to log file: %v", err)
				}
				srcPath = abf + be.CPhoreExtractedDirLinux + "bin/"
				srcFileCLI = be.CPhoreCliFile
				srcFileD = be.CPhoreDFile
				srcFileTX = be.CPhoreTxFile
			//srcFileBWCLI = be.CAppFilename
			case "amd64":
				if err := be.AddToLog(lf, "linux amd64 detected.", false); err != nil {
					return fmt.Errorf("unable to add to log file: %v", err)
				}
				srcPath = abf + be.CPhoreExtractedDirLinux + "bin/"
				srcFileCLI = be.CPhoreCliFile
				srcFileD = be.CPhoreDFile
				srcFileTX = be.CPhoreTxFile
			//srcFileBWCLI = be.CAppFilename
			default:
				err = errors.New("unable to determine runtime.GOARCH " + runtime.GOARCH)
			}
		default:
			err = errors.New("unable to determine runtime.GOOS")
		}
	case be.PTPIVX:
		if err := be.AddToLog(lf, "PIVX detected...", false); err != nil {
			return fmt.Errorf("unable to add to log file: %v", err)
		}
		switch runtime.GOOS {
		case "windows":
			srcPath = abf + be.CPIVXExtractedDirWindows + "bin\\"
			srcPathSap = abf + be.CPIVXExtractedDirWindows + "share\\pivx\\"
			srcFileCLI = be.CPIVXCliFileWin
			srcFileD = be.CPIVXDFileWin
			srcFileTX = be.CPIVXTxFileWin
			srcFileSap1 = be.CPIVXSapling1
			srcFileSap2 = be.CPIVXSapling2
			//srcFileBWCLI = be.CAppFilenameWin
		case "linux":
			switch runtime.GOARCH {
			case "arm":
				if err := be.AddToLog(lf, "linux arm detected.", false); err != nil {
					return fmt.Errorf("unable to add to log file: %v", err)
				}
				srcPath = abf + be.CPIVXExtractedDirArm + "bin/"
				srcPathSap = abf + be.CPIVXExtractedDirArm + "share/pivx/"
				srcFileCLI = be.CPIVXCliFile
				srcFileD = be.CPIVXDFile
				srcFileTX = be.CPIVXTxFile
				srcFileSap1 = be.CPIVXSapling1
				srcFileSap2 = be.CPIVXSapling2
			//srcFileBWCLI = be.CAppFilename
			case "amd64":
				if err := be.AddToLog(lf, "linux amd64 detected.", false); err != nil {
					return fmt.Errorf("unable to add to log file: %v", err)
				}
				srcPath = abf + be.CPIVXExtractedDirLinux + "bin/"
				srcPathSap = abf + be.CPIVXExtractedDirLinux + "share/pivx/"
				srcFileCLI = be.CPIVXCliFile
				srcFileD = be.CPIVXDFile
				srcFileTX = be.CPIVXTxFile
				srcFileSap1 = be.CPIVXSapling1
				srcFileSap2 = be.CPIVXSapling2
			//srcFileBWCLI = be.CAppFilename
			default:
				err = errors.New("unable to determine runtime.GOARCH " + runtime.GOARCH)
			}
		default:
			err = errors.New("unable to determine runtime.GOOS")
		}
	case be.PTRapids:
		if err := be.AddToLog(lf, "ReddCoin detected...", false); err != nil {
			return fmt.Errorf("unable to add to log file: %v", err)
		}
		switch runtime.GOOS {
		case "windows":
			srcPath = abf + be.CRapidsExtractedDirWindows
			srcFileCLI = be.CRapidsCliFileWin
			srcFileD = be.CRapidsDFileWin
			srcFileTX = be.CRapidsTxFileWin
		case "linux":
			switch runtime.GOARCH {
			case "arm":
				if err := be.AddToLog(lf, "linux arm detected.", false); err != nil {
					return fmt.Errorf("unable to add to log file: %v", err)
				}
				srcPath = abf + be.CRapidsExtractedDirLinux
				srcFileCLI = be.CRapidsCliFile
				srcFileD = be.CRapidsDFile
				srcFileTX = be.CRapidsTxFile
			case "amd64":
				if err := be.AddToLog(lf, "linux amd64 detected.", false); err != nil {
					return fmt.Errorf("unable to add to log file: %v", err)
				}
				srcPath = abf + be.CRapidsExtractedDirLinux
				srcFileCLI = be.CRapidsCliFile
				srcFileD = be.CRapidsDFile
				srcFileTX = be.CRapidsTxFile
			default:
				err = errors.New("unable to determine runtime.GOARCH " + runtime.GOARCH)
			}
		default:
			err = errors.New("unable to determine runtime.GOOS")
		}
	case be.PTReddCoin:
		if err := be.AddToLog(lf, "ReddCoin detected...", false); err != nil {
			return fmt.Errorf("unable to add to log file: %v", err)
		}
		switch runtime.GOOS {
		case "windows":
			srcPath = abf + be.CReddCoinExtractedDirWin + "bin\\"
			srcFileCLI = be.CReddCoinCliFileWin
			srcFileD = be.CReddCoinDFileWin
			srcFileTX = be.CReddCoinTxFileWin
			//srcFileBWCLI = be.CAppFilenameWin
		case "linux":
			switch runtime.GOARCH {
			case "arm":
				if err := be.AddToLog(lf, "linux arm detected.", false); err != nil {
					return fmt.Errorf("unable to add to log file: %v", err)
				}
				srcPath = abf
				srcFileCLI = be.CReddCoinCliFile
				srcFileD = be.CReddCoinDFile
				srcFileTX = be.CReddCoinTxFile
			//srcFileBWCLI = be.CAppFilename
			case "amd64":
				if err := be.AddToLog(lf, "linux amd64 detected.", false); err != nil {
					return fmt.Errorf("unable to add to log file: %v", err)
				}
				srcPath = abf + be.CReddCoinExtractedDirLinux + "bin/"
				srcFileCLI = be.CReddCoinCliFile
				srcFileD = be.CReddCoinDFile
				srcFileTX = be.CReddCoinTxFile
			//srcFileBWCLI = be.CAppFilename
			default:
				err = errors.New("unable to determine runtime.GOARCH " + runtime.GOARCH)
			}
		default:
			err = errors.New("unable to determine runtime.GOOS")
		}
	case be.PTScala:
		if err := be.AddToLog(lf, "Scala detected...", false); err != nil {
			return fmt.Errorf("unable to add to log file: %v", err)
		}
		switch runtime.GOOS {
		case "windows":
			srcPath = abf + be.CScalaExtractedDirLinux
			srcFileCLI = be.CScalaCliFileWin
			srcFileD = be.CScalaDFileWin
			srcFileTX = be.CScalaTxFileWin
			//srcFileBWCLI = be.CAppFilenameWin
		case "linux":
			switch runtime.GOARCH {
			case "arm":
				if err := be.AddToLog(lf, "linux arm detected.", false); err != nil {
					return fmt.Errorf("unable to add to log file: %v", err)
				}
				srcPath = abf + be.CScalaExtractedDirLinux
				srcFileCLI = be.CScalaCliFile
				srcFileD = be.CScalaDFile
				srcFileTX = be.CScalaTxFile
			//srcFileBWCLI = be.CAppFilename
			case "amd64":
				if err := be.AddToLog(lf, "linux amd64 detected.", false); err != nil {
					return fmt.Errorf("unable to add to log file: %v", err)
				}
				srcPath = abf + be.CScalaExtractedDirLinux
				srcFileCLI = be.CScalaCliFile
				srcFileD = be.CScalaDFile
				srcFileTX = be.CScalaTxFile
			//srcFileBWCLI = be.CAppFilename
			default:
				err = errors.New("unable to determine runtime.GOARCH " + runtime.GOARCH)
			}
		default:
			err = errors.New("unable to determine runtime.GOOS")
		}
	case be.PTTrezarcoin:
		if err := be.AddToLog(lf, "TZC detected...", false); err != nil {
			return fmt.Errorf("unable to add to log file: %v", err)
		}
		switch runtime.GOOS {
		case "windows":
			err = errors.New("windows is not currently supported for Trezarcoin")
		case "linux":
			switch runtime.GOARCH {
			case "arm":
				if err := be.AddToLog(lf, "linux arm detected.", false); err != nil {
					return fmt.Errorf("unable to add to log file: %v", err)
				}
				srcPath = abf + be.CTrezarcoinRPiExtractedDir + "/"
				srcFileCLI = be.CTrezarcoinCliFile
				srcFileD = be.CTrezarcoinDFile
				srcFileTX = be.CTrezarcoinTxFile
			case "amd64":
				if err := be.AddToLog(lf, "linux amd64 detected.", false); err != nil {
					return fmt.Errorf("unable to add to log file: %v", err)
				}
				srcPath = abf + be.CTrezarcoinLinuxExtractedDir + "bin/"
				srcFileCLI = be.CTrezarcoinCliFile
				srcFileD = be.CTrezarcoinDFile
				srcFileTX = be.CTrezarcoinTxFile
				//srcFileBWCLI = be.CAppFilename
			default:
				err = errors.New("unable to determine runtime.GOARCH " + runtime.GOARCH)
			}
		default:
			err = errors.New("unable to determine runtime.GOOS")
		}
	case be.PTVertcoin:
		if err := be.AddToLog(lf, "VTC detected...", false); err != nil {
			return fmt.Errorf("unable to add to log file: %v", err)
		}
		switch runtime.GOOS {
		case "windows":
			srcPath = abf + be.CVertcoinExtractedDirWindows
			srcFileCLI = be.CVertcoinCliFileWin
			srcFileD = be.CVertcoinDFileWin
			srcFileTX = be.CVertcoinTxFileWin
			//srcFileBWCLI = be.CAppFilenameWin
		case "linux":
			switch runtime.GOARCH {
			case "arm":
				if err := be.AddToLog(lf, "linux arm detected.", false); err != nil {
					return fmt.Errorf("unable to add to log file: %v", err)
				}
				srcPath = abf + be.CVertcoinExtractedDirLinux
				srcFileCLI = be.CVertcoinCliFile
				srcFileD = be.CVertcoinDFile
				srcFileTX = be.CVertcoinTxFile
			case "amd64":
				if err := be.AddToLog(lf, "linux amd64 detected.", false); err != nil {
					return fmt.Errorf("unable to add to log file: %v", err)
				}
				srcPath = abf + be.CVertcoinExtractedDirLinux
				srcFileCLI = be.CVertcoinCliFile
				srcFileD = be.CVertcoinDFile
				srcFileTX = be.CVertcoinTxFile
			default:
				err = errors.New("unable to determine runtime.GOARCH " + runtime.GOARCH)
			}
		default:
			err = errors.New("unable to determine runtime.GOOS")
		}
	default:
		err = errors.New("unable to determine ProjectType")
	}
	if err != nil {
		return fmt.Errorf("error: - %v", err)
	}

	be.AddToLog(lf, "srcPath="+srcPath, false)
	be.AddToLog(lf, "srcFileCLI="+srcFileCLI, false)
	be.AddToLog(lf, "srcFileD="+srcFileD, false)
	be.AddToLog(lf, "srcFileTX="+srcFileTX, false)

	// If it's PIVX, see if we need to copy the sapling files
	if bwconf.ProjectType == be.PTPIVX {
		dstSapDir, err := be.GetPIVXSaplingDir()
		if err != nil {
			return fmt.Errorf("unable to call GetPIVXSaplingDir: %v", err)
		}

		// Make sure the Sapling directory exists
		if err := os.MkdirAll(dstSapDir, os.ModePerm); err != nil {
			be.AddToLog(lf, "unable to make directory: "+err.Error(), false)
			return fmt.Errorf("unable to make dir: %v", err)
		}

		// Sapling1
		if !be.FileExists(dstSapDir + srcFileSap1) {
			if err := be.FileCopy(srcPathSap+srcFileSap1, dstSapDir+srcFileSap1, false); err != nil {
				return fmt.Errorf("unable to copyFile from: %v to %v - %v", srcPathSap+srcFileSap1, dstSapDir+srcFileSap1, err)
			}
		}
		if err := os.Chmod(dstSapDir+srcFileSap1, 0777); err != nil {
			return fmt.Errorf("unable to chmod file: %v - %v", dstSapDir+srcFileSap1, err)
		}

		// Sapling2
		if !be.FileExists(dstSapDir + srcFileSap2) {
			if err := be.FileCopy(srcPathSap+srcFileSap2, dstSapDir+srcFileSap2, false); err != nil {
				return fmt.Errorf("unable to copyFile from: %v to %v - %v", srcPathSap+srcFileSap2, dstSapDir+srcFileSap2, err)
			}
		}
		if err := os.Chmod(dstSapDir+srcFileSap2, 0777); err != nil {
			return fmt.Errorf("unable to chmod file: %v - %v", dstSapDir+srcFileSap2, err)
		}
	}

	// coin-cli
	if !be.FileExists(abf + srcFileCLI) {
		if err := be.FileCopy(srcPath+srcFileCLI, abf+srcFileCLI, false); err != nil {
			return fmt.Errorf("unable to copyFile from: %v to %v - %v", srcPath+srcFileCLI, abf+srcFileCLI, err)
		}
	}
	if err := os.Chmod(abf+srcFileCLI, 0777); err != nil {
		return fmt.Errorf("unable to chmod file: %v - %v", abf+srcFileCLI, err)
	}

	// coind
	if !be.FileExists(abf + srcFileD) {
		// This is only required for Rapids on Linux because there are 2 different directory locations.
		if srcPathD != "" {
			if err := be.FileCopy(srcPathD+srcFileD, abf+srcFileD, false); err != nil {
				return fmt.Errorf("unable to copyFile: %v - %v", srcPathD+srcFileD, err)
			}
		} else {
			if err := be.FileCopy(srcPath+srcFileD, abf+srcFileD, false); err != nil {
				return fmt.Errorf("unable to copyFile: %v - %v", srcPath+srcFileD, err)
			}
		}
	}
	err = os.Chmod(abf+srcFileD, 0777)
	if err != nil {
		return fmt.Errorf("unable to chmod file: %v - %v", abf+srcFileD, err)
	}

	// cointx
	if !be.FileExists(abf + srcFileTX) {
		if err := be.FileCopy(srcPath+srcFileTX, abf+srcFileTX, false); err != nil {
			return fmt.Errorf("unable to copyFile: %v - %v", srcPath+srcFileTX, err)
		}
	}
	err = os.Chmod(abf+srcFileTX, 0777)
	if err != nil {
		return fmt.Errorf("unable to chmod file: %v - %v", abf+srcFileTX, err)
	}

	return nil
}

func init() {
	rootCmd.AddCommand(coinCmd)

	// Here you will define your flags and configuration settings.

	// Cobra supports Persistent Flags which will work for this command
	// and all subcommands, e.g.:
	// coinCmd.PersistentFlags().String("foo", "", "A help for foo")

	// Cobra supports local flags which will only run when this command
	// is called directly, e.g.:
	// coinCmd.Flags().BoolP("toggle", "t", false, "Help message for toggle")
}
