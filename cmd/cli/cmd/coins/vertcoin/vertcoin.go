package bend

import (
	"bytes"
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
	"time"

	"github.com/mholt/archiver"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/rjminternet"
)

const (
	cCoinName       string = "Vertcoin"
	cCoinNameAbbrev string = "VTC"

	cCoreVersion       string = "0.17.1"
	cDownloadFileArm32 string = "vertcoind-v" + cCoreVersion + "-arm-linux-gnueabihf.zip"
	cDownloadFileLin64 string = "vertcoind-v" + cCoreVersion + "-linux-amd64.zip"
	cDownloadFileWin   string = "vertcoind-v" + cCoreVersion + "-win64.zip"

	cExtractedDirLin = "vertcoind-v" + cCoreVersion + "-linux-amd64/"
	cExtractedDirWin = "vertcoind-v" + cCoreVersion + "-win64\\"

	cDownloadURL string = "https://github.com/vertcoin-project/vertcoin-core/releases/download/" + cCoreVersion + "/"

	cHomeDirLin string = ".vertcoin"
	cHomeDirWin string = "VERTCOIN"

	cConfFile      string = "vertcoin.conf"
	cCliFileLin    string = "vertcoin-cli"
	cCliFileWin    string = "vertcoin-cli.exe"
	cDaemonFileLin string = "vertcoind"
	cDaemonFileWin string = "vertcoind.exe"
	cTxFileLin     string = "vertcoin-tx"
	cTxFileWin     string = "vertcoin-tx.exe"

	cTipAddress string = "vtc1q72j7fre83q8a7feppj28qkzfdt5vkcjr7xd74p"

	cRPCUser string = "vertcoinrpc"
	cRPCPort string = "5888"
)

type Vertcoin struct {
	RPCUser     string
	RPCPassword string
	IPAddress   string
	Port        string
}

func (v Vertcoin) Bootstrap(rpcUser, rpcPassword, ip, port string) {
	v.RPCUser = rpcUser
	v.RPCPassword = rpcPassword
	v.IPAddress = ip
	v.Port = port
}

func (v Vertcoin) AbbreviatedCoinName() string {
	return cCoinNameAbbrev
}

func (v Vertcoin) AllBinaryFilesExist(dir string) (bool, error) {
	if runtime.GOOS == "windows" {
		if !fileutils.FileExists(dir + cCliFileWin) {
			return false, nil
		}
		if !fileutils.FileExists(dir + cDaemonFileWin) {
			return false, nil
		}
		if !fileutils.FileExists(dir + cTxFileWin) {
			return false, nil
		}
	} else {
		if !fileutils.FileExists(dir + cCliFileLin) {
			return false, nil
		}
		if !fileutils.FileExists(dir + cDaemonFileLin) {
			return false, nil
		}
		if !fileutils.FileExists(dir + cTxFileLin) {
			return false, nil
		}
	}
	return true, nil
}

func (v Vertcoin) ConfFile() string {
	return cConfFile
}

func (v Vertcoin) CoinName() string {
	return cCoinName
}

func (v Vertcoin) CoinNameAbbrev() string {
	return cCoinNameAbbrev
}

// DownloadCoin - Downloads the Syscoin files into the spcified location.
// "location" should just be the AppBinaryFolder ~/.boxwallet
func (v Vertcoin) DownloadCoin(location string) error {
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
			return errors.New("linux 386 is not currently supported for :" + cCoinName)
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
	if err := v.unarchiveFile(fullFilePath, location); err != nil {
		return err
	}
	return nil
}

func (v Vertcoin) DaemonFilename() string {
	if runtime.GOOS == "windows" {
		return cDaemonFileWin
	} else {
		return cDaemonFileLin
	}
}

func (v *Vertcoin) BlockchainInfo() (models.VTCBlockchainInfo, error) {
	var respStruct models.VTCBlockchainInfo

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"getblockchaininfo\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+v.IPAddress+":"+v.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(v.RPCUser, v.RPCPassword)
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

func (v *Vertcoin) NetworkInfo() (models.VTCNetworkInfo, error) {
	var respStruct models.VTCNetworkInfo

	//lf := "/home/pi/.boxwallet/boxwallet.log"
	for i := 1; i < 50; i++ {
		body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"getnetworkinfo\",\"params\":[]}")

		req, err := http.NewRequest("POST", "http://"+v.IPAddress+":"+v.Port, body)
		if err != nil {
			return respStruct, err
		}
		req.SetBasicAuth(v.RPCUser, v.RPCPassword)
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

		// todo remove the below after bug fixed.
		//s := string(bodyResp)
		//AddToLog(lf, s, false)

		// Check to make sure we are not loading the wallet
		if bytes.Contains(bodyResp, []byte("Loading")) ||
			bytes.Contains(bodyResp, []byte("Rewinding")) ||
			bytes.Contains(bodyResp, []byte("Verifying")) {
			// The wallet is still loading, so print message, and sleep for 3 seconds and try again..
			time.Sleep(5 * time.Second)
		} else {
			_ = json.Unmarshal(bodyResp, &respStruct)
			return respStruct, err
		}
	}
	return respStruct, nil
}

func (v Vertcoin) RPCDefaultUsername() string {
	return cRPCUser
}

func (v Vertcoin) RPCDefaultPort() string {
	return cRPCPort
}

// func (v *Vertcoin)GetNetworkBlocksTxtVTC(bci *models.VTCBlockchainInfo) string {
// 	blocksStr := humanize.Comma(int64(bci.Result.Blocks))

// 	if blocksStr == "0" {
// 		return "Blocks:      [waiting...](fg:white)"
// 	}

// 	return "Blocks:      [" + blocksStr + "](fg:green)"
// 	//if bci.Result.Blocks > 0 {
// 	//	return "Blocks:      [" + blocksStr + "](fg:green)"
// 	//} else {
// 	//	return "[Blocks:      " + blocksStr + "](fg:red)"
// 	//}

// }

// func GetNetworkHeadersTxtVTC(bci *models.VTCBlockchainInfo) string {
// 	headersStr := humanize.Comma(int64(bci.Result.Headers))

// 	if bci.Result.Headers > 1 {
// 		return "Headers:     [" + headersStr + "](fg:green)"
// 	} else {
// 		return "[Headers:     " + headersStr + "](fg:red)"
// 	}
// }

// func GetNetworkDifficultyTxtVTC(difficulty, good, warn float64) string {
// 	var s string
// 	if difficulty > 1000 {
// 		s = humanize.FormatFloat("#.#", difficulty/1000) + "k"
// 	} else {
// 		s = humanize.Ftoa(difficulty)
// 	}

// 	// If Diff is less than 1, then we're not even calculating it properly yet...
// 	if difficulty < 1 {
// 		return "[Difficulty:  waiting...](fg:white)"
// 	}

// 	if difficulty >= good {
// 		return "Difficulty:  [" + s + "](fg:green)"
// 	} else if difficulty >= warn {
// 		return "Difficulty:  [" + s + "](fg:yellow)"
// 	} else {
// 		return "Difficulty:  [" + s + "](fg:red)"
// 	}
// }

func (v *Vertcoin) NewAddress() (models.VTCGetNewAddress, error) {
	var respStruct models.VTCGetNewAddress

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getnewaddress\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+v.IPAddress+":"+v.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(v.RPCUser, v.RPCPassword)
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

// func (v *Vertcoin)GetNetworkConnectionsTxtVTC(connections int) string {
// 	if connections == 0 {
// 		return "Peers:       [0](fg:red)"
// 	}
// 	return "Peers:       [" + strconv.Itoa(connections) + "](fg:green)"
// }

func (v *Vertcoin) WalletInfo() (models.VTCWalletInfo, error) {
	var respStruct models.VTCWalletInfo

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getwalletinfo\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+v.IPAddress+":"+v.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(v.RPCUser, v.RPCPassword)
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

	// Check to see if the json response contains "unlocked_until"
	s := string([]byte(bodyResp))
	if !strings.Contains(s, "unlocked_until") {
		respStruct.Result.UnlockedUntil = -1
	}

	return respStruct, nil
}

func (v *Vertcoin) WalletSecurityState() (models.WEType, error) {
	wi, err := v.WalletInfo()
	if err != nil {
		return models.WETUnknown, errors.New("Unable to GetWalletSecurityState: " + err.Error())
	}

	if wi.Result.UnlockedUntil == 0 {
		return models.WETLocked, nil
	} else if wi.Result.UnlockedUntil == -1 {
		return models.WETUnencrypted, nil
	} else if wi.Result.UnlockedUntil > 0 {
		return models.WETUnlockedForStaking, nil
	} else {
		return models.WETUnknown, nil
	}
}

func (v Vertcoin) HomeDir() string {
	if runtime.GOOS == "windows" {
		return cHomeDirWin
	} else {
		return cHomeDirLin
	}
}

func (v Vertcoin) HomeDirFullPath() (string, error) {
	u, err := user.Current()
	if err != nil {
		return "", err
	}
	hd := u.HomeDir

	if runtime.GOOS == "windows" {
		return fileutils.AddTrailingSlash(hd) + "appdata\\roaming\\" + fileutils.AddTrailingSlash(cHomeDirWin), nil
	} else {
		return fileutils.AddTrailingSlash(hd) + fileutils.AddTrailingSlash(cHomeDirLin), nil
	}
}

// Install - Puts the freshly downloaded files into their correct location.
// "location" should just be the AppBinaryFolder ~/.boxwallet
func (v Vertcoin) Install(location string) error {

	// Copy files to correct location
	var srcPath, sfCLI, sfD, sfTX string

	switch runtime.GOOS {
	case "windows":
		srcPath = location + cDownloadFileWin
		sfCLI = cCliFileWin
		sfD = cDaemonFileWin
		sfTX = cTxFileWin
	case "linux":
		switch runtime.GOARCH {
		case "arm", "arm64":
			srcPath = location + cExtractedDirLin
			sfCLI = cCliFileLin
			sfD = cDaemonFileLin
			sfTX = cTxFileLin
		case "amd64":
			srcPath = location + cExtractedDirLin
			sfCLI = cCliFileLin
			sfD = cDaemonFileLin
			sfTX = cTxFileLin
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

	// If the coitx file doesn't already exists the copy it.
	if _, err := os.Stat(location + sfTX); os.IsNotExist(err) {
		if err := fileutils.FileCopy(srcPath+sfTX, location+sfTX, false); err != nil {
			return fmt.Errorf("unable to copyFile from: %v to %v - %v", srcPath+sfTX, location+sfTX, err)
		}
	}
	if err := os.Chmod(location+sfTX, 0777); err != nil {
		return fmt.Errorf("unable to chmod file: %v - %v", location+sfTX, err)
	}

	return nil
}

func (v *Vertcoin) ListReceivedByAddress(includeZero bool) (models.VTCListReceivedByAddress, error) {
	var respStruct models.VTCListReceivedByAddress

	var s string
	if includeZero {
		s = "{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"listreceivedbyaddress\",\"params\":[1, true]}"
	} else {
		s = "{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"listreceivedbyaddress\",\"params\":[1, false]}"
	}
	body := strings.NewReader(s)
	req, err := http.NewRequest("POST", "http://"+v.IPAddress+":"+v.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(v.RPCUser, v.RPCPassword)
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

func (v *Vertcoin) StartDaemon(displayOutput bool) error {
	if runtime.GOOS == "windows" {
		//_ = exec.Command(GetAppsBinFolder() + cDiviDFileWin)
		fullPath := cHomeDirWin + cDaemonFileWin
		cmd := exec.Command("cmd.exe", "/C", "start", "/b", fullPath)
		if err := cmd.Run(); err != nil {
			return err
		}
	} else {
		if displayOutput {
			fmt.Println("Attempting to run the vertcoind daemon...")
		}

		cmdRun := exec.Command(cHomeDirLin + cDaemonFileLin)
		//stdout, err := cmdRun.StdoutPipe()
		err := cmdRun.Start()
		if err != nil {
			return err
		}
		fmt.Println("Vertcoin server starting")
	}
	return nil
}

func (v *Vertcoin) StopDaemon(displayOut bool) (models.GenericResponse, error) {
	var respStruct models.GenericResponse

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"stop\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+v.IPAddress+":"+v.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(v.RPCUser, v.RPCPassword)
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

func (v Vertcoin) TipAddress() string {
	return cTipAddress
}

func (v Vertcoin) unarchiveFile(fullFilePath, location string) error {
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

func (v *Vertcoin) UnlockWalletV(pw string) error {
	var respStruct models.GenericResponse

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"walletpassphrase\",\"params\":[\"" + pw + "\",0]}")
	req, err := http.NewRequest("POST", "http://"+v.IPAddress+":"+v.Port, body)
	if err != nil {
		return err
	}
	req.SetBasicAuth(v.RPCUser, v.RPCPassword)
	req.Header.Set("Content-Type", "text/plain;")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	bodyResp, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	err = json.Unmarshal(bodyResp, &respStruct)
	if err != nil {
		return err
	}
	return nil
}
