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

		// Create the App Working folder if required.
		awf, _ := be.GetAppWorkingFolder()
		if err := os.MkdirAll(awf, os.ModePerm); err != nil {
			log.Fatal("unable to make directory: ", err)
		}

		be.AddToLog(lf, "coin command invoked", false)
		prompt := &survey.Select{
			Message: "Please choose your preferred coin:",
			Options: []string{be.CCoinNameDivi,
				be.CCoinNameBitcoinPlus,
				be.CCoinNameDenarius,
				be.CCoinNameDeVault,
				be.CCoinNameDigiByte,
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
		case be.CCoinNameBitcoinPlus:
			be.AddToLog(lf, be.CCoinNameBitcoinPlus+" selected", false)
			cliConf.ProjectType = be.PTBitcoinPlus
			cliConf.Port = be.CRPCPortBitcoinPlus
		case be.CCoinNameDenarius:
			be.AddToLog(lf, be.CCoinNameDenarius+" selected", false)
			cliConf.ProjectType = be.PTDenarius
			cliConf.Port = be.CRPCPortDenarius
		case be.CCoinNameDeVault:
			be.AddToLog(lf, be.CCoinNameDeVault+" selected", false)
			cliConf.ProjectType = be.PTDeVault
			cliConf.Port = be.CRPCPortDeVault
		case be.CCoinNameDigiByte:
			be.AddToLog(lf, be.CCoinNameDigiByte+" selected", false)
			cliConf.ProjectType = be.PTDigiByte
			cliConf.Port = be.CRPCPortDigiByte
		case be.CCoinNameDivi:
			be.AddToLog(lf, be.CCoinNameDivi+" selected", false)
			cliConf.ProjectType = be.PTDivi
			cliConf.Port = be.CDiviRPCPort
		case be.CCoinNameFeathercoin:
			be.AddToLog(lf, be.CCoinNameFeathercoin+" selected", false)
			cliConf.ProjectType = be.PTFeathercoin
			cliConf.Port = be.CRPCPortFeathercoin
		case be.CCoinNameGroestlcoin:
			be.AddToLog(lf, be.CCoinNameGroestlcoin+" selected", false)
			cliConf.ProjectType = be.PTGroestlcoin
			cliConf.Port = be.CRPCPortGroestlcoin
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
		case be.CCoinNameSyscoin:
			be.AddToLog(lf, be.CCoinNameSyscoin+" selected", false)
			cliConf.ProjectType = be.PTSyscoin
			cliConf.Port = be.CSyscoinRPCPort
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

		if err := be.SetConfigStruct("", cliConf); err != nil {
			log.Fatal("Unable to write to config file: ", err)
		}
		sCoinName, err := be.GetCoinName(be.APPTCLI)
		if err != nil {
			log.Fatal("Unable to GetCoinName " + err.Error())
		}

		// Now add the coin to the coin database
		cd := be.CoinDetails{}
		cd.CoinType = cliConf.ProjectType
		cd.CoinName = sCoinName

		if err := be.AddCoin("", cd); err != nil {
			log.Fatal(err)
		}

		rpcu, rpcpw, err := be.PopulateDaemonConfFile()
		if err != nil {
			log.Fatal(err)
		}
		// ...because it's possible that the conf file for this coin has already been created, we need to store the
		// returned user and password so, effectively, will either be storing the existing info, or
		// the freshly generated info

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
			// Need check if the project is Denarius now, as that's only installable via snap
			if cliConf.ProjectType == be.PTDenarius {
				log.Fatal(be.CCoinNameDenarius + " needs to be manually installed, via the following command:" +
					"\n\n snap install denarius" + "\n\n Then run " + be.CAppFilename + " coin again")
			}

			// All or some of the project files do not exist.
			be.AddToLog(lf, "The "+sCoinName+" CLI bin files haven't been installed yet. So installing them now...", true)
			if err := doRequiredFiles(); err != nil {
				be.AddToLog(lf, "unable to complete func doRequiredFiles: "+err.Error(), false)
				log.Fatal(err)
			}
		} else {
			be.AddToLog(lf, "The "+sCoinName+" CLI bin files have already been installed.", true)
		}

		// I think here is the best place to check whether the user would like to download the blockchain snapshot..
		switch cliConf.ProjectType {
		case be.PTDenarius:
			bcdExists, _ := be.BlockchainDataExists(be.PTDenarius)
			if !bcdExists {
				ans := true
				prompt := &survey.Confirm{
					Message: "\nIt looks like this is a fresh install of " + be.CCoinNameDenarius +
						"\n\nWould you like to download the Blockchain snapshot " + be.CDFBSDenarius + " ?:",
					Default: true,
				}
				survey.AskOne(prompt, &ans)
				if ans {
					fmt.Println("Downloading blockchain snapshot...")
					if err := be.DownloadBlockchain(be.PTDenarius); err != nil {
						log.Fatal("Unable to download blockchain snapshot: " + err.Error())
					}
					fmt.Println("Unarchiving blockchain snapshot...")
					if err := be.UnarchiveBlockchainSnapshot(be.PTDenarius); err != nil {
						log.Fatal("Unable to unarchive blockchain snapshot: " + err.Error())
					}
				}

			}
		case be.PTDivi:
			bcdExists, _ := be.BlockchainDataExists(be.PTDivi)
			if !bcdExists {
				ans := true
				prompt := &survey.Confirm{
					Message: "\nIt looks like this is a fresh install of " + be.CCoinNameDivi +
						"\n\nWould you like to download the Blockchain snapshot " + be.CDFDiviBS + " ?:",
					Default: true,
				}
				survey.AskOne(prompt, &ans)
				if ans {
					fmt.Println("Downloading blockchain snapshot...")
					if err := be.DownloadBlockchain(be.PTDivi); err != nil {
						log.Fatal("Unable to download blockchain snapshot: " + err.Error())
					}
					fmt.Println("Unarchiving blockchain snapshot...")
					if err := be.UnarchiveBlockchainSnapshot(be.PTDivi); err != nil {
						log.Fatal("Unable to unarchive blockchain snapshot: " + err.Error())
					}
				}

			}
		case be.PTReddCoin:
			bcdExists, _ := be.BlockchainDataExists(be.PTReddCoin)
			if !bcdExists {
				ans := true
				prompt := &survey.Confirm{
					Message: "\nIt looks like this is a fresh install of " + be.CCoinNameReddCoin +
						"\n\nWould you like to download the Blockchain snapshot " + be.CDFReddCoinBS + " ?:",
					Default: true,
				}
				survey.AskOne(prompt, &ans)
				if ans {
					fmt.Println("Downloading blockchain snapshot...")
					if err := be.DownloadBlockchain(be.PTReddCoin); err != nil {
						log.Fatal("Unable to download blockchain snapshot: " + err.Error())
					}
					fmt.Println("Unarchiving blockchain snapshot...")
					if err := be.UnarchiveBlockchainSnapshot(be.PTReddCoin); err != nil {
						log.Fatal("Unable to unarchive blockchain snapshot: " + err.Error())
					}
				}

			}
		}

		fmt.Println("\nAll done!")
		fmt.Println("\nYou can now run './boxwallet start' and then './boxwallet dash' to view your " + sCoinName + " Dashboard")

		sTipInfo := be.GetTipInfo(cliConf.ProjectType)
		fmt.Println("\n\n" + sTipInfo)
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
	case be.PTBitcoinPlus:
		switch runtime.GOOS {
		case "windows":
			return fmt.Errorf("Windows is not currently supported for BitcoinPlus: %v ", err)
		case "linux":
			switch runtime.GOARCH {
			case "arm":
				return fmt.Errorf("ARM32 is not currently supported by BitcoinPlus: %v ", err)
			case "arm64":
				return fmt.Errorf("ARM64 is not currently supported by BitcoinPlus: %v ", err)
			case "386":
				filePath = abf + be.CDFFileLinux32BitcoinPlus
				fileURL = be.CDownloadURLBitcoinPlus + be.CDFFileLinux32BitcoinPlus
			case "amd64":
				filePath = abf + be.CDFFileLinux64BitcoinPlus
				fileURL = be.CDownloadURLBitcoinPlus + be.CDFFileLinux64BitcoinPlus
			}
		}
	case be.PTDeVault:
		if runtime.GOOS == "windows" {
			filePath = abf + be.CDFWindowsDeVault
			fileURL = be.CDownloadURLDeVault + be.CDFWindowsDeVault
		} else if runtime.GOARCH == "arm" {
			filePath = abf + be.CDFRPiDeVault
			fileURL = be.CDownloadURLDeVault + be.CDFRPiDeVault
		} else {
			filePath = abf + be.CDFLinuxDeVault
			fileURL = be.CDownloadURLDeVault + be.CDFLinuxDeVault
		}
	case be.PTDigiByte:
		switch runtime.GOOS {
		case "windows":
			filePath = abf + be.CDFWindowsDigiByte
			fileURL = be.CDownloadURLDigiByte + be.CDFWindowsDigiByte
		case "linux":
			switch runtime.GOARCH {
			case "arm":
				return fmt.Errorf("ARM32 is not currently supported by DigiByte: %v ", err)
			case "arm64":
				filePath = abf + be.CDFArm64DigiByte
				fileURL = be.CDownloadURLDigiByte + be.CDFArm64DigiByte
			case "386":
				filePath = abf + be.CDFLinuxDigiByte
				fileURL = be.CDownloadURLDigiByte + be.CDFLinuxDigiByte
			case "amd64":
				filePath = abf + be.CDFLinuxDigiByte
				fileURL = be.CDownloadURLDigiByte + be.CDFLinuxDigiByte
			}
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
			filePath = abf + be.CDFWindowsFeathercoin
			fileURL = be.CDownloadURLFeathercoin + be.CDFWindowsFeathercoin
		} else if runtime.GOARCH == "arm" {
			return fmt.Errorf("ARM is not supported for this build: %v ", err)
		} else {
			filePath = abf + be.CDFLinuxFeathercoin
			fileURL = be.CDownloadURLFeathercoin + be.CDFLinuxFeathercoin
		}
	case be.PTGroestlcoin:
		if runtime.GOOS == "windows" {
			filePath = abf + be.CDFWindowsGroestlcoin
			fileURL = be.CDownloadURLGroestlcoin + be.CDFWindowsGroestlcoin
		} else if runtime.GOARCH == "arm" {
			filePath = abf + be.CDFRPiGroestlcoin
			fileURL = be.CDownloadURLGroestlcoin + be.CDFRPiGroestlcoin
		} else {
			filePath = abf + be.CDFLinuxGroestlcoin
			fileURL = be.CDownloadURLGroestlcoin + be.CDFLinuxGroestlcoin
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
			filePath = abf + be.CDFPIVXFileArm32
			fileURL = be.CDownloadURLPIVX + be.CDFPIVXFileArm32
		} else if runtime.GOARCH == "arm64" {
			filePath = abf + be.CDFPIVXFileArm64
			fileURL = be.CDownloadURLPIVX + be.CDFPIVXFileArm64
		} else {
			filePath = abf + be.CDFPIVXFileLinux
			fileURL = be.CDownloadURLPIVX + be.CDFPIVXFileLinux
		}
	case be.PTRapids:
		if runtime.GOOS == "windows" {
			filePath = abf + be.CDFRapidsFileWindows
			fileURL = be.CDownloadURLRapids + be.CDFRapidsFileWindows
		} else if runtime.GOARCH == "arm" {
			return fmt.Errorf("ARM is not currently supported by Rapids at present: %v ", err)
		} else {
			filePath = abf + be.CDFRapidsFileLinux
			//filePath2 = abf + be.CDFRapidsFileLinuxDaemon
			fileURL = be.CDownloadURLRapids + be.CDFRapidsFileLinux
			//fileURL2 = be.CDownloadURLRapids + be.CDFRapidsFileLinuxDaemon
		}
	case be.PTReddCoin:
		switch runtime.GOOS {
		case "windows":
			filePath = abf + be.CDFReddCoinWindows
			fileURL = be.CDownloadURLReddCoinGen + be.CDFReddCoinWindows
		case "linux":
			switch runtime.GOARCH {
			case "arm":
				filePath = abf + be.CDFReddCoinRPi
				fileURL = be.CDownloadURLReddCoinArm
			case "arm64":
				return fmt.Errorf("ARM64 is not currently supported by ReddCoin: %v ", err)
			case "386":
				filePath = abf + be.CDFReddCoinLinux32
				fileURL = be.CDownloadURLReddCoinGen + be.CDFReddCoinLinux32
			case "amd64":
				filePath = abf + be.CDFReddCoinLinux64
				fileURL = be.CDownloadURLReddCoinGen + be.CDFReddCoinLinux64
			}
		}
		//if runtime.GOOS == "windows" {
		//	filePath = abf + be.CDFReddCoinWindows
		//	fileURL = be.CDownloadURLReddCoinGen + be.CDFReddCoinWindows
		//} else if runtime.GOARCH == "arm" {
		//	filePath = abf + be.CDFReddCoinRPi
		//	fileURL = be.CDownloadURLReddCoinArm
		//} else {
		//	filePath = abf + be.CDFReddCoinLinux64
		//	fileURL = be.CDownloadURLReddCoinGen + be.CDFReddCoinLinux64
		//}
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
	case be.PTSyscoin:
		switch runtime.GOOS {
		case "windows":
			filePath = abf + be.CDFSyscoinFileWindows
			fileURL = be.CDownloadURLSyscoin + be.CDFSyscoinFileWindows
		case "linux":
			switch runtime.GOARCH {
			case "arm":
				return fmt.Errorf("ARM32 is not currently supported by DigiByte: %v ", err)
			case "arm64":
				filePath = abf + be.CDFSyscoinFileArm64
				fileURL = be.CDownloadURLSyscoin + be.CDFSyscoinFileArm64
			case "386":
				filePath = abf + be.CDFSyscoinFileLinux
				fileURL = be.CDownloadURLSyscoin + be.CDFSyscoinFileLinux
			case "amd64":
				filePath = abf + be.CDFSyscoinFileLinux
				fileURL = be.CDownloadURLDigiByte + be.CDFSyscoinFileLinux
			}
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
			filePath = abf + be.CDFVertcoinRPi
			fileURL = be.CDownloadURLVertcoin + be.CDFVertcoinRPi
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
	case be.PTBitcoinPlus:
		switch runtime.GOOS {
		case "windows":
			if err := archiver.Unarchive(filePath, abf); err != nil {
				return fmt.Errorf("unable to unarchive file: %v - %v", r, err)
			}
			defer os.RemoveAll(abf + be.CExtractedDirWindowsBitcoinPlus)
		case "linux":
			switch runtime.GOARCH {
			case "arm64":
				err = archiver.Unarchive(filePath, abf)
				if err != nil {
					return fmt.Errorf("unable to unarchive file: %v - %v", r, err)
				}
				defer os.RemoveAll(abf + be.CExtractedDirLinuxBitcoinPlus)
			case "386":
				err = archiver.Unarchive(filePath, abf)
				if err != nil {
					return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
				}
				//defer os.RemoveAll(abf + be.CExtractedDirLinuxBitcoinPlus)
			case "amd64":
				err = archiver.Unarchive(filePath, abf)
				if err != nil {
					return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
				}
				//defer os.RemoveAll(abf + be.CExtractedDirLinuxBitcoinPlus)
			}
		}
	case be.PTDeVault:
		if runtime.GOOS == "windows" {
			if err := archiver.Unarchive(filePath, abf); err != nil {
				return fmt.Errorf("unable to unarchive file: %v - %v", r, err)
			}
			defer os.RemoveAll(abf + be.CExtractedDirWinDeVault)
		} else if runtime.GOARCH == "arm" {
			//err = be.ExtractTarGz(r)
			err = archiver.Unarchive(filePath, abf)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll(abf + be.CExtractedDirLinuxDeVault)
		} else {
			err = archiver.Unarchive(filePath, abf)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll(abf + be.CExtractedDirLinuxDeVault)
		}
	case be.PTDigiByte:
		switch runtime.GOOS {
		case "windows":
			if err := archiver.Unarchive(filePath, abf); err != nil {
				return fmt.Errorf("unable to unarchive file: %v - %v", r, err)
			}
			defer os.RemoveAll(abf + be.CExtractedDirWindowsDigiByte)
		case "linux":
			switch runtime.GOARCH {
			case "arm64":
				err = archiver.Unarchive(filePath, abf)
				if err != nil {
					return fmt.Errorf("unable to unarchive file: %v - %v", r, err)
				}
				defer os.RemoveAll(abf + be.CExtractedDirLinuxDigiByte)
			case "386":
				err = archiver.Unarchive(filePath, abf)
				if err != nil {
					return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
				}
				defer os.RemoveAll(abf + be.CExtractedDirLinuxDigiByte)
			case "amd64":
				err = archiver.Unarchive(filePath, abf)
				if err != nil {
					return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
				}
				defer os.RemoveAll(abf + be.CExtractedDirLinuxDigiByte)
			}
		}
	case be.PTDivi:
		if runtime.GOOS == "windows" {
			if err := archiver.Unarchive(filePath, abf); err != nil {
				return fmt.Errorf("unable to unarchive file: %v - %v", r, err)
			}
			defer os.RemoveAll(abf + be.CDiviExtractedDirWindows)
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
			return fmt.Errorf("feathercoin is not supported on Windows at this point")
		} else if runtime.GOARCH == "arm" {
			//err = be.ExtractTarGz(r)
			err = archiver.Unarchive(filePath, abf)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll(abf + be.CExtractedDirLinuxFeathercoin)
		} else {
			//err = be.ExtractTarGz(r)
			err = archiver.Unarchive(filePath, abf)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll(abf + be.CExtractedDirLinuxFeathercoin)
		}
	case be.PTGroestlcoin:
		if runtime.GOOS == "windows" {
			if err := archiver.Unarchive(filePath, abf); err != nil {
				return fmt.Errorf("unable to unarchive file: %v - %v", r, err)
			}
			defer os.RemoveAll(abf + be.CExtractedDirWindowsGroestlcoin)
		} else if runtime.GOARCH == "arm" {
			//err = be.ExtractTarGz(r)
			err = archiver.Unarchive(filePath, abf)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll(abf + be.CExtractedDirLinuxGroestlcoin)
		} else {
			//err = be.ExtractTarGz(r)
			err = archiver.Unarchive(filePath, abf)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll(abf + be.CExtractedDirLinuxGroestlcoin)
		}
	case be.PTPhore:
		if runtime.GOOS == "windows" {
			if err := archiver.Unarchive(filePath, abf); err != nil {
				return fmt.Errorf("unable to unarchive file: %v - %v", r, err)
			}
			defer os.RemoveAll(abf + be.CPhoreExtractedDirWindows)
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
			if err := archiver.Unarchive(filePath, abf); err != nil {
				return fmt.Errorf("unable to unarchive file: %v - %v", r, err)
			}
			defer os.RemoveAll(abf + be.CPIVXExtractedDirWindows)
		} else if runtime.GOARCH == "arm" {
			//err = be.ExtractTarGz(r)
			err = archiver.Unarchive(filePath, abf)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll(abf + be.CPIVXExtractedDirArm)
		} else if runtime.GOARCH == "arm64" {
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
			if err := archiver.Unarchive(filePath, abf); err != nil {
				return fmt.Errorf("unable to unarchive file: %v - %v", r, err)
			}
			defer os.RemoveAll(abf + be.CRapidsExtractedDirWindows)
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
		switch runtime.GOOS {
		case "windows":
			//_, err = be.UnZip(filePath, abf)
			//if err != nil {
			//	return fmt.Errorf("unable to unzip file: %v - %v", filePath, err)
			//}
			if err := archiver.Unarchive(filePath, abf); err != nil {
				return fmt.Errorf("unable to unarchive file: %v - %v", r, err)
			}

			defer os.RemoveAll(abf + be.CReddCoinExtractedDirWin)
		case "linux":
			switch runtime.GOARCH {
			case "arm":
				err = archiver.Unarchive(filePath, abf)
				if err != nil {
					return fmt.Errorf("unable to unarchive file: %v - %v", r, err)
				}
				defer os.RemoveAll(abf + be.CReddCoinExtractedDirLinux)
			case "386":
				err = archiver.Unarchive(filePath, abf)
				if err != nil {
					return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
				}
				defer os.RemoveAll(abf + be.CReddCoinExtractedDirLinux)
			case "amd64":
				err = archiver.Unarchive(filePath, abf)
				if err != nil {
					return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
				}
				defer os.RemoveAll(abf + be.CReddCoinExtractedDirLinux)
			default:
				err = errors.New("unable to determine runtime.GOARCH " + runtime.GOARCH)
			}
		}
	case be.PTScala:
		if runtime.GOOS == "windows" {
			if err := archiver.Unarchive(filePath, abf); err != nil {
				return fmt.Errorf("unable to unarchive file: %v - %v", r, err)
			}

			// todo Correctly remove the Windows extracted dir below.
			//defer os.RemoveAll(abf + be.CScalaExtractedDirLinux)
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
	case be.PTSyscoin:
		switch runtime.GOOS {
		case "windows":
			if err := archiver.Unarchive(filePath, abf); err != nil {
				return fmt.Errorf("unable to unarchive file: %v - %v", r, err)
			}
			defer os.RemoveAll(abf + be.CSyscoinExtractedDirWindows)
		case "linux":
			switch runtime.GOARCH {
			case "arm64":
				err = archiver.Unarchive(filePath, abf)
				if err != nil {
					return fmt.Errorf("unable to unarchive file: %v - %v", r, err)
				}
				defer os.RemoveAll(abf + be.CSyscoinExtractedDirLinux)
			case "386":
				err = archiver.Unarchive(filePath, abf)
				if err != nil {
					return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
				}
				defer os.RemoveAll(abf + be.CSyscoinExtractedDirLinux)
			case "amd64":
				err = archiver.Unarchive(filePath, abf)
				if err != nil {
					return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
				}
				defer os.RemoveAll(abf + be.CSyscoinExtractedDirLinux)
			}
		}
	case be.PTTrezarcoin:
		if runtime.GOOS == "windows" {
			return fmt.Errorf("trezarcoin is not supported on Windows at this point")
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
			if err := archiver.Unarchive(filePath, abf); err != nil {
				return fmt.Errorf("unable to unarchive file: %v - %v", r, err)
			}
			defer os.RemoveAll(abf + be.CVertcoinExtractedDirWindows)
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
	case be.PTBitcoinPlus:
		if err := be.AddToLog(lf, "BitcoinPlus detected...", false); err != nil {
			return fmt.Errorf("unable to add to log file: %v", err)
		}
		switch runtime.GOOS {
		case "windows":
			srcPath = abf + be.CExtractedDirWindowsBitcoinPlus
			srcFileCLI = be.CCliFileWinBitcoinPlus
			srcFileD = be.CDFileWinBitcoinPlus
			srcFileTX = be.CTxFileWinBitcoinPlus
			//srcFileBWCLI = be.CAppFilenameWin
		case "linux":
			switch runtime.GOARCH {
			case "arm", "arm64":
				if err := be.AddToLog(lf, "linux arm detected.", false); err != nil {
					return fmt.Errorf("unable to add to log file: %v", err)
				}
				srcPath = abf + be.CExtractedDirLinuxBitcoinPlus
				srcFileCLI = be.CCliFileBitcoinPlus
				srcFileD = be.CDFileBitcoinPlus
				srcFileTX = be.CTxFileBitcoinPlus
			case "386":
				if err := be.AddToLog(lf, "linux 386 detected.", false); err != nil {
					return fmt.Errorf("unable to add to log file: %v", err)
				}
				srcPath = abf + be.CExtractedDirLinuxBitcoinPlus
				srcFileCLI = be.CCliFileBitcoinPlus
				srcFileD = be.CDFileBitcoinPlus
				srcFileTX = be.CTxFileBitcoinPlus
			//srcFileBWCLI = be.CAppFilename
			case "amd64":
				if err := be.AddToLog(lf, "linux amd64 detected.", false); err != nil {
					return fmt.Errorf("unable to add to log file: %v", err)
				}
				srcPath = abf + be.CExtractedDirLinuxBitcoinPlus
				srcFileCLI = be.CCliFileBitcoinPlus
				srcFileD = be.CDFileBitcoinPlus
				srcFileTX = be.CTxFileBitcoinPlus
			//srcFileBWCLI = be.CAppFilename
			default:
				err = errors.New("unable to determine runtime.GOARCH " + runtime.GOARCH)
			}
		default:
			err = errors.New("unable to determine runtime.GOOS")
		}
	case be.PTDeVault:
		if err := be.AddToLog(lf, "DeVault detected...", false); err != nil {
			return fmt.Errorf("unable to add to log file: %v", err)
		}
		switch runtime.GOOS {
		case "windows":
			srcPath = abf + be.CExtractedDirWinDeVault + "bin\\"
			srcFileCLI = be.CCliFileWinDeVault
			srcFileD = be.CDFileWinDeVault
			srcFileTX = be.CTxFileWinDeVault
			//srcFileBWCLI = be.CAppFilenameWin
		case "linux":
			switch runtime.GOARCH {
			case "arm":
				if err := be.AddToLog(lf, "linux arm detected.", false); err != nil {
					return fmt.Errorf("unable to add to log file: %v", err)
				}
				srcPath = abf + be.CExtractedDirLinuxDeVault + "bin/"
				srcFileCLI = be.CCliFileDeVault
				srcFileD = be.CDFileDeVault
				srcFileTX = be.CTxFileDeVault
			//srcFileBWCLI = be.CAppFilename
			case "386", "amd64":
				if err := be.AddToLog(lf, "linux amd64 detected.", false); err != nil {
					return fmt.Errorf("unable to add to log file: %v", err)
				}
				srcPath = abf + be.CExtractedDirLinuxDeVault + "bin/"
				srcFileCLI = be.CCliFileDeVault
				srcFileD = be.CDFileDeVault
				srcFileTX = be.CTxFileDeVault
			//srcFileBWCLI = be.CAppFilename
			default:
				err = errors.New("unable to determine runtime.GOARCH " + runtime.GOARCH)
			}
		default:
			err = errors.New("unable to determine runtime.GOOS")
		}
	case be.PTDigiByte:
		if err := be.AddToLog(lf, "DigiByte detected...", false); err != nil {
			return fmt.Errorf("unable to add to log file: %v", err)
		}
		switch runtime.GOOS {
		case "windows":
			srcPath = abf + be.CExtractedDirWindowsDigiByte + "bin\\"
			srcFileCLI = be.CCliFileWinDigiByte
			srcFileD = be.CDFileWinDigiByte
			srcFileTX = be.CTxFileWinDigiByte
			//srcFileBWCLI = be.CAppFilenameWin
		case "linux":
			switch runtime.GOARCH {
			case "arm", "arm64":
				if err := be.AddToLog(lf, "linux arm detected.", false); err != nil {
					return fmt.Errorf("unable to add to log file: %v", err)
				}
				srcPath = abf + be.CExtractedDirLinuxDigiByte + "bin/"
				srcFileCLI = be.CCliFileDigiByte
				srcFileD = be.CDFileDigiByte
				srcFileTX = be.CTxFileDigiByte
			case "386":
				if err := be.AddToLog(lf, "linux 386 detected.", false); err != nil {
					return fmt.Errorf("unable to add to log file: %v", err)
				}
				srcPath = abf + be.CExtractedDirLinuxDigiByte + "bin/"
				srcFileCLI = be.CCliFileDigiByte
				srcFileD = be.CDFileDigiByte
				srcFileTX = be.CTxFileDigiByte
			//srcFileBWCLI = be.CAppFilename
			case "amd64":
				if err := be.AddToLog(lf, "linux amd64 detected.", false); err != nil {
					return fmt.Errorf("unable to add to log file: %v", err)
				}
				srcPath = abf + be.CExtractedDirLinuxDigiByte + "bin/"
				srcFileCLI = be.CCliFileDigiByte
				srcFileD = be.CDFileDigiByte
				srcFileTX = be.CTxFileDigiByte
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
			case "386", "amd64":
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
			srcPath = abf + be.CExtractedDirLinuxFeathercoin
			srcFileCLI = be.CCliFileWinFeathercoin
			srcFileD = be.CDFileWinFeathercoin
			srcFileTX = be.CTxFileWinFeathercoin
			//srcFileBWCLI = be.CAppFilenameWin
		case "linux":
			switch runtime.GOARCH {
			case "arm":
				if err := be.AddToLog(lf, "linux arm detected.", false); err != nil {
					return fmt.Errorf("unable to add to log file: %v", err)
				}
				srcPath = abf + be.CExtractedDirLinuxFeathercoin
				srcFileCLI = be.CCliFileFeathercoin
				srcFileD = be.CDFileFeathercoin
				srcFileTX = be.CTxFileFeathercoin
			//srcFileBWCLI = be.CAppFilename
			case "386", "amd64":
				if err := be.AddToLog(lf, "linux amd64 detected.", false); err != nil {
					return fmt.Errorf("unable to add to log file: %v", err)
				}
				srcPath = abf + be.CExtractedDirLinuxFeathercoin
				srcFileCLI = be.CCliFileFeathercoin
				srcFileD = be.CDFileFeathercoin
				srcFileTX = be.CTxFileFeathercoin
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
			srcPath = abf + be.CExtractedDirWindowsGroestlcoin + "bin\\"
			srcFileCLI = be.CCliFileWinGroestlcoin
			srcFileD = be.CDFileWinGroestlcoin
			srcFileTX = be.CTxFileWinGroestlcoin
			//srcFileBWCLI = be.CAppFilenameWin
		case "linux":
			switch runtime.GOARCH {
			case "arm":
				if err := be.AddToLog(lf, "linux arm detected.", false); err != nil {
					return fmt.Errorf("unable to add to log file: %v", err)
				}
				srcPath = abf + be.CExtractedDirLinuxGroestlcoin + "bin/"
				srcFileCLI = be.CCliFileGroestlcoin
				srcFileD = be.CDFileGroestlcoin
				srcFileTX = be.CTxFileGroestlcoin
			//srcFileBWCLI = be.CAppFilename
			case "386", "amd64":
				if err := be.AddToLog(lf, "linux amd64 detected.", false); err != nil {
					return fmt.Errorf("unable to add to log file: %v", err)
				}
				srcPath = abf + be.CExtractedDirLinuxGroestlcoin + "bin/"
				srcFileCLI = be.CCliFileGroestlcoin
				srcFileD = be.CDFileGroestlcoin
				srcFileTX = be.CTxFileGroestlcoin
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
			case "386", "amd64":
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
			case "arm", "arm64":
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
			case "386", "amd64":
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
			case "386", "amd64":
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
			case "386":
				if err := be.AddToLog(lf, "linux 386 detected.", false); err != nil {
					return fmt.Errorf("unable to add to log file: %v", err)
				}
				srcPath = abf + be.CReddCoinExtractedDirLinux + "bin/"
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
			case "386", "amd64":
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
	case be.PTSyscoin:
		if err := be.AddToLog(lf, "Syscoin detected...", false); err != nil {
			return fmt.Errorf("unable to add to log file: %v", err)
		}
		switch runtime.GOOS {
		case "windows":
			srcPath = abf + be.CSyscoinExtractedDirWindows + "bin\\"
			srcFileCLI = be.CSyscoinCliFileWin
			srcFileD = be.CSyscoinDFileWin
			srcFileTX = be.CSyscoinTxFileWin
			//srcFileBWCLI = be.CAppFilenameWin
		case "linux":
			switch runtime.GOARCH {
			case "arm", "arm64":
				if err := be.AddToLog(lf, "linux arm detected.", false); err != nil {
					return fmt.Errorf("unable to add to log file: %v", err)
				}
				srcPath = abf + be.CSyscoinExtractedDirLinux + "bin/"
				srcFileCLI = be.CSyscoinCliFile
				srcFileD = be.CSyscoinDFile
				srcFileTX = be.CSyscoinTxFile
			case "386":
				if err := be.AddToLog(lf, "linux 386 detected.", false); err != nil {
					return fmt.Errorf("unable to add to log file: %v", err)
				}
				srcPath = abf + be.CSyscoinExtractedDirLinux + "bin/"
				srcFileCLI = be.CSyscoinCliFile
				srcFileD = be.CSyscoinDFile
				srcFileTX = be.CSyscoinTxFile
			//srcFileBWCLI = be.CAppFilename
			case "amd64":
				if err := be.AddToLog(lf, "linux amd64 detected.", false); err != nil {
					return fmt.Errorf("unable to add to log file: %v", err)
				}
				srcPath = abf + be.CSyscoinExtractedDirLinux + "bin/"
				srcFileCLI = be.CSyscoinCliFile
				srcFileD = be.CSyscoinDFile
				srcFileTX = be.CSyscoinTxFile
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
			case "386", "amd64":
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
			case "386", "amd64":
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

	if err := be.AddToLog(lf, "srcPath="+srcPath, false); err != nil {
		return fmt.Errorf("unable to add to log file: %v", err)
	}
	if err := be.AddToLog(lf, "srcFileCLI="+srcFileCLI, false); err != nil {
		return fmt.Errorf("unable to add to log file: %v", err)
	}
	if err := be.AddToLog(lf, "srcFileD="+srcFileD, false); err != nil {
		return fmt.Errorf("unable to add to log file: %v", err)
	}
	if err := be.AddToLog(lf, "srcFileTX="+srcFileTX, false); err != nil {
		return fmt.Errorf("unable to add to log file: %v", err)
	}

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
