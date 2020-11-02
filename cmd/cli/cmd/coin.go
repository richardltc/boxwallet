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
	"path/filepath"
	be "richardmace.co.uk/boxwallet/cmd/cli/cmd/bend"
	"runtime"

	//_ "github.com/AlecAivazis/survey/v2"
	"github.com/artdarek/go-unzip"
	"github.com/spf13/cobra"
)

// coinCmd represents the coin command
var coinCmd = &cobra.Command{
	Use:   "coin",
	Short: "The coin command is used to specify which coin you wish to work with",
	Long:  ``,
	Run: func(cmd *cobra.Command, args []string) {
		fmt.Println("  ____          __          __   _ _      _   \n |  _ \\         \\ \\        / /  | | |    | |  \n | |_) | _____  _\\ \\  /\\  / /_ _| | | ___| |_ \n |  _ < / _ \\ \\/ /\\ \\/  \\/ / _` | | |/ _ \\ __|\n | |_) | (_) >  <  \\  /\\  / (_| | | |  __/ |_ \n |____/ \\___/_/\\_\\  \\/  \\/ \\__,_|_|_|\\___|\\__|\n                                              \n                                              ")
		coin := ""
		prompt := &survey.Select{
			Message: "Please choose your preferred coin:",
			Options: []string{be.CCoinNameDivi, be.CCoinNameFeathercoin, be.CCoinNameGroestlcoin, be.CCoinNamePhore, be.CCoinNameTrezarcoin, be.CCoinNameVertcoin},
		}
		survey.AskOne(prompt, &coin)
		cliConf := be.ConfStruct{}
		cliConf.ServerIP = "127.0.0.1"

		switch coin {
		case be.CCoinNameDivi:
			cliConf.ProjectType = be.PTDivi
			cliConf.Port = be.CDiviRPCPort
		case be.CCoinNameFeathercoin:
			cliConf.ProjectType = be.PTFeathercoin
			cliConf.Port = be.CFeathercoinRPCPort
		case be.CCoinNameGroestlcoin:
			cliConf.ProjectType = be.PTGroestlcoin
			cliConf.Port = be.CGroestlcoinRPCPort
		case be.CCoinNamePhore:
			cliConf.ProjectType = be.PTPhore
			cliConf.Port = be.CPhoreRPCPort
		case be.CCoinNamePIVX:
			cliConf.ProjectType = be.PTPIVX
			cliConf.Port = be.CPIVXRPCPort
		case be.CCoinNameTrezarcoin:
			cliConf.ProjectType = be.PTTrezarcoin
			cliConf.Port = be.CTrezarcoinRPCPort
		case be.CCoinNameVertcoin:
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

		rpcu, rpcpw, err := be.PopulateDaemonConfFile()
		if err != nil {
			log.Fatal(err)
		}
		// because it's possible that the conf file for this coin has already been created, we need to store the returned user and password
		// so, effectively, will either be storing the existing info, or the freshly generated info
		cliConf.RPCuser = rpcu
		cliConf.RPCpassword = rpcpw
		err = be.SetConfigStruct("", cliConf)
		if err != nil {
			log.Fatal(err)
		}

		b, err := be.AllProjectBinaryFilesExists()
		if !b {
			fmt.Println("The " + sCoinName + " CLI bin files haven't been installed yet. So installing them now...")
			if err := doRequiredFiles(); err != nil {
				log.Fatal(err)
			}
		} else {
			fmt.Println("The " + sCoinName + " CLI bin files have already been installed.")
		}
		fmt.Println("\nAll done!")
		fmt.Println("\nYou can now run './boxwallet start' and then './boxwallet dash' to view your " + sCoinName + " Dashboard")
	},
}

// doRequiredFiles - Download and install required files
func doRequiredFiles() error {
	var filePath, fileURL string
	//abf, err := be.GetAppsBinFolder()
	ex, err := os.Executable()
	if err != nil {
		return fmt.Errorf("Unable to retrieve running binary: %v ", err)
	}
	abf := be.AddTrailingSlash(filepath.Dir(ex))

	bwconf, err := be.GetConfigStruct("", true)
	if err != nil {
		return fmt.Errorf("Unable to get CLIConfigStruct: %v ", err)
	}
	switch bwconf.ProjectType {
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
	case be.PTTrezarcoin:
		if runtime.GOOS == "windows" {
			filePath = abf + be.CDFTrezarcoinWindows
			fileURL = be.CDownloadURLTC + be.CDFTrezarcoinWindows
		} else if runtime.GOARCH == "arm" {
			filePath = abf + be.CDFTrezarcoinRPi
			fileURL = be.CDownloadURLTC + be.CDFTrezarcoinRPi
		} else {
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

	log.Print("Downloading required files...")
	if err := be.DownloadFile(filePath, fileURL); err != nil {
		return fmt.Errorf("unable to download file: %v - %v", filePath+fileURL, err)
	}
	//https://github.com/Groestlcoin/groestlcoin/releases/download/v2.20.1/groestlcoin-2.20.1-x86_64-linux-gnu.tar.gz
	defer os.Remove(filePath)

	r, err := os.Open(filePath)
	if err != nil {
		return fmt.Errorf("unable to open file: %v - %v", filePath, err)
	}

	// Now, decompress the files...
	log.Print("decompressing files...")
	switch bwconf.ProjectType {
	case be.PTDivi:
		if runtime.GOOS == "windows" {
			_, err = be.UnZip(filePath, "tmp")
			if err != nil {
				return fmt.Errorf("unable to unzip file: %v - %v", filePath, err)
			}
			defer os.RemoveAll("tmp")
		} else if runtime.GOARCH == "arm" {
			err = be.ExtractTarGz(r)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll("./" + be.CDiviExtractedDir)
		} else {
			err = be.ExtractTarGz(r)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll("./" + be.CDiviExtractedDir)
		}
	case be.PTFeathercoin:
		if runtime.GOOS == "windows" {
			_, err = be.UnZip(filePath, "tmp")
			if err != nil {
				return fmt.Errorf("unable to unzip file: %v - %v", filePath, err)
			}
			defer os.RemoveAll("tmp")
		} else if runtime.GOARCH == "arm" {
			err = be.ExtractTarGz(r)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll("./" + be.CFeathercoinExtractedDirLinux)
		} else {
			err = be.ExtractTarGz(r)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll("./" + be.CFeathercoinExtractedDirLinux)
		}
	case be.PTGroestlcoin:
		if runtime.GOOS == "windows" {
			_, err = be.UnZip(filePath, "tmp")
			if err != nil {
				return fmt.Errorf("unable to unzip file: %v - %v", filePath, err)
			}
			defer os.RemoveAll("tmp")
		} else if runtime.GOARCH == "arm" {
			err = be.ExtractTarGz(r)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll("./" + be.CGroestlcoinExtractedDirLinux)
		} else {
			//data, _ := ioutil.ReadFile("path/to/file.tar.bz2")
			//buffer := bytes.NewBuffer(data)
			//extract.Bz2(data, "/path/where/to/extract", nil)

			err = be.ExtractTarGz(r)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll("./" + be.CGroestlcoinExtractedDirLinux)
		}
	case be.PTPhore:
		if runtime.GOOS == "windows" {
			_, err = be.UnZip(filePath, "tmp")
			if err != nil {
				return fmt.Errorf("unable to unzip file: %v - %v", filePath, err)
			}
			defer os.RemoveAll("tmp")
		} else if runtime.GOARCH == "arm" {
			err = be.ExtractTarGz(r)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll("./" + be.CPhoreExtractedDir)
		} else {
			err = be.ExtractTarGz(r)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll("./" + be.CPhoreExtractedDir)
		}
	case be.PTPIVX:
		if runtime.GOOS == "windows" {
			_, err = be.UnZip(filePath, "tmp")
			if err != nil {
				return fmt.Errorf("unable to unzip file: %v - %v", filePath, err)
			}
			defer os.RemoveAll("tmp")
		} else if runtime.GOARCH == "arm" {
			err = be.ExtractTarGz(r)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll("./" + be.CPIVXExtractedDirArm)
		} else {
			err = be.ExtractTarGz(r)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll("./" + be.CPIVXExtractedDirLinux)
		}
	case be.PTTrezarcoin:
		if runtime.GOOS == "windows" {
			_, err = be.UnZip(filePath, "tmp")
			if err != nil {
				return fmt.Errorf("unable to unzip file: %v - %v", filePath, err)
			}
			defer os.RemoveAll("tmp")
		} else if runtime.GOARCH == "arm" {
			err = be.ExtractTarGz(r)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
		} else {
			err = be.ExtractTarGz(r)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll("./" + be.CTrezarcoinExtractedDir)
		}
	case be.PTVertcoin:
		if runtime.GOOS == "windows" {
			_, err = be.UnZip(filePath, "tmp")
			if err != nil {
				return fmt.Errorf("unable to unzip file: %v - %v", filePath, err)
			}
			defer os.RemoveAll("tmp")
		} else if runtime.GOARCH == "arm" {
			err = be.ExtractTarGz(r)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll("./" + be.CVertcoinExtractedDirLinux)
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

	log.Print("Installing files...")

	// Copy files to correct location
	var srcPath, srcFileCLI, srcFileD, srcFileTX string //srcFileBWConfCLI, srcFileBWCLI string

	switch bwconf.ProjectType {
	case be.PTDivi:
		switch runtime.GOOS {
		case "windows":
			srcPath = "./tmp/" + be.CDiviExtractedDir + "bin/"
			srcFileCLI = be.CDiviCliFileWin
			srcFileD = be.CDiviDFileWin
			srcFileTX = be.CDiviTxFileWin
			//srcFileBWCLI = be.CAppFilenameWin
		case "arm":
			srcPath = "./" + be.CDiviExtractedDir + "bin/"
			srcFileCLI = be.CDiviCliFile
			srcFileD = be.CDiviDFile
			srcFileTX = be.CDiviTxFile
			//srcFileBWCLI = be.CAppFilename
		case "linux":
			srcPath = "./" + be.CDiviExtractedDir + "bin/"
			srcFileCLI = be.CDiviCliFile
			srcFileD = be.CDiviDFile
			srcFileTX = be.CDiviTxFile
			//srcFileBWCLI = be.CAppFilename
		default:
			err = errors.New("unable to determine runtime.GOOS")
		}
	case be.PTFeathercoin:
		switch runtime.GOOS {
		case "windows":
			srcPath = "./tmp/" + be.CFeathercoinExtractedDirLinux
			srcFileCLI = be.CFeathercoinCliFileWin
			srcFileD = be.CFeathercoinDFileWin
			srcFileTX = be.CFeathercoinTxFileWin
			//srcFileBWCLI = be.CAppFilenameWin
		case "arm":
			srcPath = "./" + be.CFeathercoinExtractedDirLinux
			srcFileCLI = be.CFeathercoinCliFile
			srcFileD = be.CFeathercoinDFile
			srcFileTX = be.CFeathercoinTxFile
			//srcFileBWCLI = be.CAppFilename
		case "linux":
			srcPath = "./" + be.CFeathercoinExtractedDirLinux
			srcFileCLI = be.CFeathercoinCliFile
			srcFileD = be.CFeathercoinDFile
			srcFileTX = be.CFeathercoinTxFile
			//srcFileBWCLI = be.CAppFilename
		default:
			err = errors.New("unable to determine runtime.GOOS")
		}
	case be.PTGroestlcoin:
		switch runtime.GOOS {
		case "windows":
			srcPath = "./tmp/" + be.CGroestlcoinExtractedDirLinux + "bin/"
			srcFileCLI = be.CGroestlcoinCliFileWin
			srcFileD = be.CGroestlcoinDFileWin
			srcFileTX = be.CGroestlcoinTxFileWin
			//srcFileBWCLI = be.CAppFilenameWin
		case "arm":
			srcPath = "./" + be.CGroestlcoinExtractedDirLinux + "bin/"
			srcFileCLI = be.CGroestlcoinCliFile
			srcFileD = be.CGroestlcoinDFile
			srcFileTX = be.CGroestlcoinTxFile
			//srcFileBWCLI = be.CAppFilename
		case "linux":
			srcPath = "./" + be.CGroestlcoinExtractedDirLinux + "bin/"
			srcFileCLI = be.CGroestlcoinCliFile
			srcFileD = be.CGroestlcoinDFile
			srcFileTX = be.CGroestlcoinTxFile
			//srcFileBWCLI = be.CAppFilename
		default:
			err = errors.New("unable to determine runtime.GOOS")
		}
	case be.PTPhore:
		switch runtime.GOOS {
		case "windows":
			srcPath = "./tmp/" + be.CPhoreExtractedDir + "bin/"
			srcFileCLI = be.CPhoreCliFileWin
			srcFileD = be.CPhoreDFileWin
			srcFileTX = be.CPhoreTxFileWin
			//srcFileBWCLI = be.CAppFilenameWin
		case "arm":
			srcPath = "./" + be.CPhoreExtractedDir + "bin/"
			srcFileCLI = be.CPhoreCliFile
			srcFileD = be.CPhoreDFile
			srcFileTX = be.CPhoreTxFile
			//srcFileBWCLI = be.CAppFilename
		case "linux":
			srcPath = "./" + be.CPhoreExtractedDir + "bin/"
			srcFileCLI = be.CPhoreCliFile
			srcFileD = be.CPhoreDFile
			srcFileTX = be.CPhoreTxFile
			//srcFileBWCLI = be.CAppFilename
		default:
			err = errors.New("unable to determine runtime.GOOS")
		}
	case be.PTPIVX:
		switch runtime.GOOS {
		case "windows":
			srcPath = "./tmp/" + be.CPIVXExtractedDirWindows + "pivx-" + be.CPIVXCoreVersion + "bin/"
			srcFileCLI = be.CPIVXCliFileWin
			srcFileD = be.CPIVXDFileWin
			srcFileTX = be.CPIVXTxFileWin
			//srcFileBWCLI = be.CAppFilenameWin
		case "arm":
			srcPath = "./" + be.CPIVXExtractedDirArm + "bin/"
			srcFileCLI = be.CPIVXCliFile
			srcFileD = be.CPIVXDFile
			srcFileTX = be.CPIVXTxFile
			//srcFileBWCLI = be.CAppFilename
		case "linux":
			srcPath = "./" + be.CPIVXExtractedDirLinux + "bin/"
			srcFileCLI = be.CPIVXCliFile
			srcFileD = be.CPIVXDFile
			srcFileTX = be.CPIVXTxFile
			//srcFileBWCLI = be.CAppFilename
		default:
			err = errors.New("unable to determine runtime.GOOS")
		}
	case be.PTTrezarcoin:
		switch runtime.GOOS {
		case "windows":
			err = errors.New("windows is not currently supported for Trezarcoin")
		case "arm":
			err = errors.New("arm is not currently supported for Trezarcoin")
		case "linux":
			srcPath = "./" + be.CTrezarcoinExtractedDir + "bin/"
			srcFileCLI = be.CTrezarcoinCliFile
			srcFileD = be.CTrezarcoinDFile
			srcFileTX = be.CTrezarcoinTxFile
			//srcFileBWCLI = be.CAppFilename
		default:
			err = errors.New("unable to determine runtime.GOOS")
		}
	case be.PTVertcoin:
		switch runtime.GOOS {
		case "windows":
			srcPath = "./tmp/" + be.CVertcoinExtractedDirLinux
			srcFileCLI = be.CVertcoinCliFileWin
			srcFileD = be.CVertcoinDFileWin
			srcFileTX = be.CVertcoinTxFileWin
			//srcFileBWCLI = be.CAppFilenameWin
		case "arm":
			srcPath = "./" + be.CVertcoinExtractedDirLinux
			srcFileCLI = be.CVertcoinCliFile
			srcFileD = be.CVertcoinDFile
			srcFileTX = be.CVertcoinTxFile
			//srcFileBWCLI = be.CAppFilename
		case "linux":
			srcPath = "./" + be.CVertcoinExtractedDirLinux
			srcFileCLI = be.CVertcoinCliFile
			srcFileD = be.CVertcoinDFile
			srcFileTX = be.CVertcoinTxFile
			//srcFileBWCLI = be.CAppFilename
		default:
			err = errors.New("unable to determine runtime.GOOS")
		}
	default:
		err = errors.New("unable to determine ProjectType")
	}
	if err != nil {
		return fmt.Errorf("error: - %v", err)
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
		if err := be.FileCopy(srcPath+srcFileD, abf+srcFileD, false); err != nil {
			return fmt.Errorf("unable to copyFile: %v - %v", srcPath+srcFileD, err)
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
