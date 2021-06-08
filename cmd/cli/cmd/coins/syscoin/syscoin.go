package coins

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/ioutil"
	"net/http"
	"os"
	"os/exec"
	"os/user"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/fileutils"
	"runtime"
	"strings"

	"github.com/mholt/archiver/v3"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/rjminternet"
)

const (
	cCoinName       string = "Syscoin"
	cCoinNameAbbrev string = "SYS"

	cCoreVersion       string = "4.2.2"
	cDownloadFileArm32        = "syscoin-" + cCoreVersion + "-arm-linux-gnueabihf.tar.gz"
	cDownloadFileArm64        = "syscoin-" + cCoreVersion + "-aarch64-linux-gnu.tar.gz"
	cDownloadFileLin          = "syscoin-" + cCoreVersion + "-x86_64-linux-gnu.tar.gz"
	cDownloadFilemacOS        = "syscoin-" + cCoreVersion + "-osx64.tar.gz"
	cDownloadFileWin          = "syscoin-" + cCoreVersion + "-win64.zip"

	// Directory const
	cExtractedDirArm string = "syscoin-" + cCoreVersion + "/"
	cExtractedDirLin string = "syscoin-" + cCoreVersion + "/"
	cExtractedDirWin string = "syscoin-" + cCoreVersion + "\\"

	cDownloadURL string = "https://github.com/syscoin/syscoin/releases/download/v" + cCoreVersion + "/"

	// Syscoin Wallet Constants
	cHomeDir    string = ".syscoin"
	cHomeDirWin string = "syscoin"

	// File constants
	cConfFile   string = "syscoin.conf"
	cCliFile    string = "syscoin-cli"
	cCliFileWin string = "syscoin-cli.exe"
	cDFileLin   string = "syscoind"
	cDFileWin   string = "syscoind.exe"
	cTxFile     string = "syscoin-tx"
	cTxFileWin  string = "syscoin-tx.exe"

	cTipAddress string = "sys1qkj3tfnpndluj85k5vmfzccxfsl6nt4kn6slxey"

	cRPCUser string = "syscoinrpc"
	cRPCPort string = "8370"
)

type Syscoin struct {
	RPCUser     string
	RPCPassword string
	IPAddress   string
	Port        string
}

func (s Syscoin) Bootstrap(rpcUser, rpcPassword, ip, port string) {
	s.RPCUser = rpcUser
	s.RPCPassword = rpcPassword
	s.IPAddress = ip
	s.Port = port
}

func (s Syscoin) AbbreviatedCoinName() string {
	return cCoinNameAbbrev
}

func (s Syscoin) AllBinaryFilesExist(dir string) (bool, error) {
	if runtime.GOOS == "windows" {
		if !fileutils.FileExists(dir + cCliFileWin) {
			return false, nil
		}
		if !fileutils.FileExists(dir + cDFileWin) {
			return false, nil
		}
		if !fileutils.FileExists(dir + cTxFileWin) {
			return false, nil
		}
	} else {
		if !fileutils.FileExists(dir + cCliFile) {
			return false, nil
		}
		if !fileutils.FileExists(dir + cDFileLin) {
			return false, nil
		}
		if !fileutils.FileExists(dir + cTxFile) {
			return false, nil
		}
	}
	return true, nil
}

func (s Syscoin) ConfFile() string {
	return cConfFile
}

func (s Syscoin) CoinName() string {
	return cCoinName
}

func (s Syscoin) CoinNameAbbrev() string {
	return cCoinNameAbbrev
}

// DownloadCoin - Downloads the Syscoin files into the spcified location.
// "location" should just be the AppBinaryFolder ~/.boxwallet
func (s Syscoin) DownloadCoin(location string) error {
	var fullFilePath, fullFileDLURL string

	switch runtime.GOOS {
	case "windows":
		fullFilePath = location + cDownloadFileWin
		fullFileDLURL = cDownloadURL + cDownloadFileWin
	case "linux":
		switch runtime.GOARCH {
		case "arm":
			fullFilePath = location + cDownloadFileArm32
			fullFileDLURL = cDownloadURL + cDownloadFileArm32
		case "arm64":
			fullFilePath = location + cDownloadFileArm64
			fullFileDLURL = cDownloadURL + cDownloadFileArm64
		case "386":
			return errors.New("linux 386 is not currently supported for :" + cCoinName)
		case "amd64":
			fullFilePath = location + cDownloadFileLin
			fullFileDLURL = cDownloadURL + cDownloadFileLin
		}
	}

	if err := rjminternet.DownloadFile(fullFilePath, fullFileDLURL); err != nil {
		return fmt.Errorf("unable to download file: %v - %v", fullFilePath+fullFileDLURL, err)
	}

	// Unarchive the files
	if err := s.unarchiveFile(fullFilePath, location); err != nil {
		return err
	}
	return nil
}

func (s Syscoin) DaemonFilename() string {
	if runtime.GOOS == "windows" {
		return cDFileWin
	} else {
		return cDFileLin
	}
}

func (s Syscoin) HomeDir() string {
	if runtime.GOOS == "windows" {
		return cHomeDirWin
	} else {
		return cHomeDir
	}
}

func (s Syscoin) HomeDirFullPath() (string, error) {
	u, err := user.Current()
	if err != nil {
		return "", err
	}
	hd := u.HomeDir

	if runtime.GOOS == "windows" {
		return fileutils.AddTrailingSlash(hd) + "appdata\\roaming\\" + fileutils.AddTrailingSlash(cHomeDirWin), nil
	} else {
		return fileutils.AddTrailingSlash(hd) + fileutils.AddTrailingSlash(cHomeDir), nil
	}
}

// Install - Puts the freshly downloaded files into their correct location.
// "location" should just be the AppBinaryFolder ~/.boxwallet
func (s Syscoin) Install(location string) error {

	// Copy files to correct location
	var srcPath, sfCLI, sfD, sfTX, dirToRemove string

	switch runtime.GOOS {
	case "windows":
		srcPath = location + cDownloadFileWin
		sfCLI = cCliFileWin
		sfD = cDFileWin
		sfTX = cTxFileWin
	case "linux":
		switch runtime.GOARCH {
		case "arm", "arm64":
			srcPath = location + cExtractedDirLin + "bin/"
			sfCLI = cCliFile
			sfD = cDFileLin
			sfTX = cTxFile
			dirToRemove = location + cExtractedDirLin
		case "amd64":
			srcPath = location + cExtractedDirLin + "bin/"
			sfCLI = cCliFile
			sfD = cDFileLin
			sfTX = cTxFile
			dirToRemove = location + cExtractedDirLin
		default:
			return errors.New("unable to determine runtime.GOARCH " + runtime.GOARCH)
		}
	default:
		return errors.New("unable to determine runtime.GOOS")
	}

	// If the coin-cli file doesn't already exists the copy it.
	if _, err := os.Stat(location + sfCLI); os.IsNotExist(err) {
		if err := fileutils.FileCopy(srcPath+sfCLI, location+sfCLI, false); err != nil {
			return fmt.Errorf("unable to copyFile from: %v to %v - %v", srcPath+sfCLI, location+sfCLI, err)
		}
	}
	if err := os.Chmod(location+sfCLI, 0777); err != nil {
		return fmt.Errorf("unable to chmod file: %v - %v", location+sfCLI, err)
	}

	// If the coind file doesn't already exists the copy it.
	if _, err := os.Stat(location + sfD); os.IsNotExist(err) {
		if err := fileutils.FileCopy(srcPath+sfD, location+sfD, false); err != nil {
			return fmt.Errorf("unable to copyFile from: %v to %v - %v", srcPath+sfD, location+sfD, err)
		}
	}
	if err := os.Chmod(location+sfD, 0777); err != nil {
		return fmt.Errorf("unable to chmod file: %v - %v", location+sfD, err)
	}

	// If the cointx file doesn't already exists the copy it.
	if _, err := os.Stat(location + sfTX); os.IsNotExist(err) {
		if err := fileutils.FileCopy(srcPath+sfTX, location+sfTX, false); err != nil {
			return fmt.Errorf("unable to copyFile from: %v to %v - %v", srcPath+sfTX, location+sfTX, err)
		}
	}
	if err := os.Chmod(location+sfTX, 0777); err != nil {
		return fmt.Errorf("unable to chmod file: %v - %v", location+sfTX, err)
	}

	_ = os.RemoveAll(dirToRemove)

	return nil
}

func (s Syscoin) RPCDefaultUsername() string {
	return cRPCUser
}

func (s Syscoin) RPCDefaultPort() string {
	return cRPCPort
}

func (s *Syscoin) StartDaemon(displayOutput bool) error {
	if runtime.GOOS == "windows" {
		fp := cHomeDirWin + cDFileWin
		cmd := exec.Command("cmd.exe", "/C", "start", "/b", fp)
		if err := cmd.Run(); err != nil {
			return err
		}
	} else {
		if displayOutput {
			fmt.Println("Attempting to run the " + cCoinName + " daemon...")
		}

		cmdRun := exec.Command(cHomeDir + cDFileLin)
		//stdout, err := cmdRun.StdoutPipe()
		//if err != nil {
		//	return err
		//}
		if err := cmdRun.Start(); err != nil {
			return err
		}
		if displayOutput {
			fmt.Println(cCoinName + " server starting")
		}

	}
	return nil
}

func (s *Syscoin) StopDaemon(ip, port, rpcUser, rpcPassword string, displayOut bool) (models.GenericResponse, error) {
	var respStruct models.GenericResponse

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"stop\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+ip+":"+port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(rpcUser, rpcPassword)
	req.Header.Set("Content-Type", "text/plain;")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return respStruct, err
	}
	defer resp.Body.Close()
	bodyResp, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return respStruct, err
	}
	err = json.Unmarshal(bodyResp, &respStruct)
	if err != nil {
		return respStruct, err
	}
	return respStruct, nil
}

func (s Syscoin) TipAddress() string {
	return cTipAddress
}

func (s *Syscoin) unarchiveFile(fullFilePath, location string) error {
	if err := archiver.Unarchive(fullFilePath, location); err != nil {
		return fmt.Errorf("unable to unarchive file: %v - %v", fullFilePath, err)
	}
	switch runtime.GOOS {
	case "windows":
		defer os.RemoveAll(location + cDownloadFileWin)
	case "linux":
		switch runtime.GOARCH {
		case "arm":
			defer os.RemoveAll(location + cDownloadFileArm32)
		case "arm64":
			defer os.RemoveAll(location + cDownloadFileArm64)
		case "386":
			return errors.New("linux 386 is not currently supported for :" + cCoinName)
		case "amd64":
			defer os.RemoveAll(location + cDownloadFileLin)
		}
	}

	defer os.Remove(fullFilePath)

	return nil
}