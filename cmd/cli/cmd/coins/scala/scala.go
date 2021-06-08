package bend

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/ioutil"
	"net/http"
	"os"
	"os/exec"
	"runtime"
	"strings"

	"github.com/mholt/archiver"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/rjminternet"
)

const (
	cCoinName       string = "Scala"
	cCoinNameAbbrev string = "XLA"

	cCoreVersion       string = "4.1.0"
	cDownloadFileArm32 string = "arm-" + cCoreVersion + "-rPI.zip"
	cDownloadFileLin64 string = "linux-x64-" + cCoreVersion + ".zip"
	cDownloadFileWin   string = "windows-x64-v" + cCoreVersion + ".zip"

	cExtractedDirLin = "bin/"

	cDownloadURL string = "https://github.com/scala-network/Scala/releases/download/v" + cCoreVersion + "/"

	cHomeDir    string = ".scala"
	cHomeDirWin string = "SCALA"

	cConfFile      string = "scala.conf"
	cCliFileLin    string = "scala-wallet-cli"
	cCliFileWin    string = "scala-wallet-cli.exe"
	cDaemonFileLin string = "scalad"
	cDaemonFileWin string = "scalad.exe"
	cTxFileLin     string = "scala-wallet-rpc"
	cTxFileWin     string = "scala-wallet-rpc.exe"

	cRPCUser string = "scalarpc"
	cRPCPort string = "11812"
)

type Scala struct {
	RPCUser     string
	RPCPassword string
	IPAddress   string
	Port        string
}

func (s *Scala) Bootstrap(rpcUser, rpcPassword, ip, port string) {
	s.RPCUser = rpcUser
	s.RPCPassword = rpcPassword
	s.IPAddress = ip
	s.Port = port
}

func (s *Scala) AbbreviatedCoinName() string {
	return cCoinNameAbbrev
}

func (s *Scala) AllBinaryFilesExist(dir string) (bool, error) {
	if runtime.GOOS == "windows" {
		if !fileExists(dir + cCliFileWin) {
			return false, nil
		}
		if !fileExists(dir + cDaemonFileWin) {
			return false, nil
		}
		if !fileExists(dir + cTxFileWin) {
			return false, nil
		}
	} else {
		if !fileExists(dir + cCliFileLin) {
			return false, nil
		}
		if !fileExists(dir + cDaemonFileLin) {
			return false, nil
		}
		if !fileExists(dir + cTxFileLin) {
			return false, nil
		}
	}
	return true, nil
}

func (s *Scala) ConfFile() string {
	return cConfFile
}

func (s Scala) CoinName() string {
	return cCoinName
}

func (s Scala) CoinNameAbbrev() string {
	return cCoinNameAbbrev
}

// DownloadCoin - Downloads the Scala files into the spcified location.
// "location" should just be the AppBinaryFolder ~/.boxwallet
func (s *Scala) DownloadCoin(location string) error {
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
			return errors.New("arm64 is not currently supported for :" + cCoinName)
		case "386":
			return errors.New("linux 386 is not currently supported for :" + cCoinName)
		case "amd64":
			fullFilePath = location + cDownloadFileLin64
			fullFileDLURL = cDownloadURL + cDownloadFileLin64
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

func (s *Scala) DaemonFilename() string {
	if runtime.GOOS == "windows" {
		return cDaemonFileWin
	} else {
		return cDaemonFileLin
	}
}

func (s *Scala) GetBlockCountXLA() (models.XLABlockCount, error) {
	var respStruct models.XLABlockCount

	body := strings.NewReader("{\"jsonrpc\":\"2.0\",\"id\":\"boxwallet\",\"method\":\"get_block_count\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+s.IPAddress+":"+s.Port+"/json_rpc", body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(s.RPCUser, s.RPCPassword)
	req.Header.Set("Content-Type", "application/json")

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

func (s *Scala) StartDaemon(displayOutput bool) error {
	if runtime.GOOS == "windows" {
		//_ = exec.Command(GetAppsBinFolder() + cDiviDFileWin)
		fp := cHomeDirWin + cDaemonFileWin
		cmd := exec.Command("cmd.exe", "/C", "start", "/b", fp)
		if err := cmd.Run(); err != nil {
			return err
		}
	} else {
		if displayOutput {
			fmt.Println("Attempting to run the scala daemon...")
		}

		args := []string{"--detach"}
		cmdRun := exec.Command(cHomeDir+cDaemonFileLin, args...)
		//stdout, err := cmdRun.StdoutPipe()
		err := cmdRun.Start()
		if err != nil {
			return err
		}
		fmt.Println("Scala server starting")
	}
	return nil
}

func (s *Scala) StopDaemon(ip, port, rpcUser, rpcPassword string, displayOut bool) (models.GenericResponse, error) {
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

func addTrailingSlash(filePath string) string {
	var lastChar = filePath[len(filePath)-1:]
	switch runtime.GOOS {
	case "windows":
		if lastChar == "\\" {
			return filePath
		} else {
			return filePath + "\\"
		}
	case "linux":
		if lastChar == "/" {
			return filePath
		} else {
			return filePath + "/"
		}
	}

	return ""
}

func fileCopy(srcFile, destFile string, dispOutput bool) error {
	// Open original file
	originalFile, err := os.Open(srcFile)
	if err != nil {
		return err
	}
	defer originalFile.Close()

	// Create new file
	newFile, err := os.Create(destFile)
	if err != nil {
		return err
	}
	defer newFile.Close()

	// Copy the bytes to destination from source
	bytesWritten, err := io.Copy(newFile, originalFile)
	if err != nil {
		return err
	}
	if dispOutput {
		fmt.Printf("Copied %d bytes.", bytesWritten)
	}

	// Commit the file contents
	// Flushes memory to disk
	err = newFile.Sync()
	if err != nil {
		return err
	}

	return nil
}

func fileExists(filename string) bool {
	info, err := os.Stat(filename)
	if os.IsNotExist(err) {
		return false
	}
	return !info.IsDir()
}

func (s *Scala) unarchiveFile(fullFilePath, location string) error {
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
			return errors.New("arm64 is not currently supported for :" + cCoinName)
		case "386":
			return errors.New("linux 386 is not currently supported for :" + cCoinName)
		case "amd64":
			defer os.RemoveAll(location + cDownloadFileLin64)
		}
	}

	defer os.Remove(fullFilePath)

	return nil
}
