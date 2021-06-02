package bend

import (
	"bufio"
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
	cCoinName       string = "Trezarcoin"
	cCoinNameAbbrev string = "TZC"

	cCoreVersion       string = "2.1.3"
	cDownloadFileArm32 string = cCoreVersion + "-rpi.zip"
	cDownloadFileLin64 string = "trezarcoin-" + cCoreVersion + "-linux64.tar.gz"
	cDownloadFileWin   string = "trezarcoin-" + cCoreVersion + "-win64-setup.exe"

	cExtractedDirLin = "trezarcoin-" + cCoreVersion + "/"
	cExtractedDirArm = cCoreVersion + "-rpi/"

	cDownloadURL string = "https://github.com/TrezarCoin/TrezarCoin/releases/download/v" + cCoreVersion + ".0/"

	cHomeDirLin string = ".trezarcoin"
	cHomeDirWin string = "TREZARCOIN"

	cConfFile      string = "trezarcoin.conf"
	cCliFileLin    string = "trezarcoin-cli"
	cCliFileWin    string = "trezarcoin-cli.exe"
	cDaemonFileLin string = "trezarcoind"
	cDaemonFileWin string = "trezarcoind.exe"
	cTxFileLin     string = "trezarcoin-tx"
	cTxFileWin     string = "trezarcoin-tx.exe"

	cTipAddress string = "TnkHScr6iTcfK11GDPFjNgJ7V3GZtHEy9V"

	// trezarcoin.conf file constant.
	cRPCUser string = "trezarcoinrpc"
	cRPCPort string = "17299"
)

type Trezarcoin struct {
	RPCUser     string
	RPCPassword string
	IPAddress   string
	Port        string
}

func (t Trezarcoin) Bootstrap(rpcUser, rpcPassword, ip, port string) {
	t.RPCUser = rpcUser
	t.RPCPassword = rpcPassword
	t.IPAddress = ip
	t.Port = port
}

func (t Trezarcoin) AbbreviatedCoinName() string {
	return cCoinNameAbbrev
}

func (t Trezarcoin) AllBinaryFilesExist(dir string) (bool, error) {
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

func (t Trezarcoin) ConfFile() string {
	return cConfFile
}

func (s Trezarcoin) CoinName() string {
	return cCoinName
}

func (s Trezarcoin) CoinNameAbbrev() string {
	return cCoinNameAbbrev
}

// DownloadCoin - Downloads the Trezarcoin files into the spcified location.
// "location" should just be the AppBinaryFolder ~/.boxwallet
func (t Trezarcoin) DownloadCoin(location string) error {
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
	if err := t.unarchiveFile(fullFilePath, location); err != nil {
		return err
	}
	return nil
}

func (t Trezarcoin) DaemonFilename() string {
	if runtime.GOOS == "windows" {
		return cDaemonFileWin
	} else {
		return cDaemonFileLin
	}
}

func (t *Trezarcoin) BlockchainInfo() (models.TZCBlockchainInfo, error) {
	var respStruct models.TZCBlockchainInfo

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getblockchaininfo\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+t.IPAddress+":"+t.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(t.RPCUser, t.RPCPassword)
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

func (t Trezarcoin) HomeDir() string {
	if runtime.GOOS == "windows" {
		return cHomeDirWin
	} else {
		return cHomeDirLin
	}
}

func (t Trezarcoin) HomeDirFullPath() (string, error) {
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
func (t Trezarcoin) Install(location string) error {

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
			srcPath = location + cExtractedDirArm
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

func (t *Trezarcoin) Info() (models.TZCGetInfo, error) {
	//attempts := 5
	//waitingStr := "Checking server..."

	var respStruct models.TZCGetInfo

	for i := 1; i < 50; i++ {
		//fmt.Printf("\r"+waitingStr+" %d/"+strconv.Itoa(attempts), i)
		body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"getinfo\",\"params\":[]}")
		req, err := http.NewRequest("POST", "http://"+t.IPAddress+":"+t.Port, body)
		if err != nil {
			return respStruct, err
		}
		req.SetBasicAuth(t.RPCUser, t.RPCPassword)
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

		//s := string(bodyResp)
		//AddToLog(lf,s,false)
		// Check to make sure we are not loading the wallet
		if bytes.Contains(bodyResp, []byte("Loading")) ||
			bytes.Contains(bodyResp, []byte("Rewinding")) ||
			bytes.Contains(bodyResp, []byte("Verifying")) {
			// The wallet is still loading, so print message, and sleep for 3 seconds and try again..
			var errStruct models.GenericResponse
			err = json.Unmarshal(bodyResp, &errStruct)
			if err != nil {
				return respStruct, err
			}
			//fmt.Println("Waiting for wallet to load...")
			time.Sleep(5 * time.Second)
		} else {

			_ = json.Unmarshal(bodyResp, &respStruct)
			return respStruct, err
		}
	}
	return respStruct, nil
}

func (t Trezarcoin) RPCDefaultUsername() string {
	return cRPCUser
}

func (t Trezarcoin) RPCDefaultPort() string {
	return cRPCPort
}

// func (t *Trezarcoin)GetNetworkBlocksTxtTrezarcoin(bci *models.TZCBlockchainInfo) string {
// 	blocksStr := humanize.Comma(int64(bci.Result.Blocks))

// 	if bci.Result.Blocks > 100 {
// 		return "Blocks:      [" + blocksStr + "](fg:green)"
// 	} else {
// 		return "[Blocks:      " + blocksStr + "](fg:red)"
// 	}
// }

// func GetNetworkConnectionsTxtTZC(connections int) string {
// 	if connections == 0 {
// 		return "Peers:       [0](fg:red)"
// 	}
// 	return "Peers:       [" + strconv.Itoa(connections) + "](fg:green)"
// }

// func GetBlockchainSyncTxtTrezarcoin(synced bool, bci *models.TZCBlockchainInfo) string {
// 	s := ConvertBCVerification(bci.Result.Verificationprogress)
// 	if s == "0.0" {
// 		s = ""
// 	} else {
// 		s = s + "%"
// 	}

// 	if !synced {
// 		if bci.Result.Verificationprogress > gLastBCSyncPos {
// 			gLastBCSyncPos = bci.Result.Verificationprogress
// 			return "Blockchain:  [syncing " + s + " ](fg:yellow)"
// 		} else {
// 			gLastBCSyncPos = bci.Result.Verificationprogress
// 			return "Blockchain:  [waiting " + s + " ](fg:yellow)"
// 		}
// 	} else {
// 		return "Blockchain:  [synced " + CUtfTickBold + "](fg:green)"
// 	}
// }

// func GetNetworkDifficultyTxtTrezarcoin(difficulty, good, warn float64) string {
// 	var s string
// 	if difficulty > 1000 {
// 		s = humanize.FormatFloat("#.#", difficulty/1000) + "k"
// 	} else {
// 		s = humanize.Ftoa(difficulty)
// 	}
// 	if difficulty >= good {
// 		return "Difficulty:  [" + s + "](fg:green)"
// 	} else if difficulty >= warn {
// 		return "[Difficulty:  " + s + "](fg:yellow)"
// 	} else {
// 		return "[Difficulty:  " + s + "](fg:red)"
// 	}
// }

func (t *Trezarcoin) StakingInfo() (models.TZCStakingInfo, error) {
	var respStruct models.TZCStakingInfo

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getstakinginfo\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+t.IPAddress+":"+t.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(t.RPCUser, t.RPCPassword)
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

func (t Trezarcoin) TipAddress() string {
	return cTipAddress
}

func (t *Trezarcoin) WalletInfo() (models.TZCWalletInfo, error) {
	var respStruct models.TZCWalletInfo

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getwalletinfo\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+t.IPAddress+":"+t.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(t.RPCUser, t.RPCPassword)
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

func (t *Trezarcoin) WalletSecurityState() (models.WEType, error) {
	wi, err := t.WalletInfo()
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

func (t *Trezarcoin) ListReceivedByAddress(includeZero bool) (models.TZCListReceivedByAddress, error) {
	var respStruct models.TZCListReceivedByAddress

	var s string
	if includeZero {
		s = "{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"listreceivedbyaddress\",\"params\":[1, true]}"
	} else {
		s = "{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"listreceivedbyaddress\",\"params\":[1, false]}"
	}
	body := strings.NewReader(s)
	req, err := http.NewRequest("POST", "http://"+t.IPAddress+":"+t.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(t.RPCUser, t.RPCPassword)
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

func (t *Trezarcoin) ListTranactions() (models.TZCListTransactions, error) {
	var respStruct models.TZCListTransactions

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"listtransactions\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+t.IPAddress+":"+t.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(t.RPCUser, t.RPCPassword)
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

func (t *Trezarcoin) StartDaemon(displayOutput bool) error {
	if runtime.GOOS == "windows" {
		fp := cHomeDirWin + cDaemonFileWin
		cmd := exec.Command("cmd.exe", "/C", "start", "/b", fp)
		if err := cmd.Run(); err != nil {
			return err
		}
	} else {
		if displayOutput {
			fmt.Println("Attempting to run the trezarcoin daemon...")
		}

		cmdRun := exec.Command(cHomeDirLin + cDaemonFileLin)
		stdout, err := cmdRun.StdoutPipe()
		if err != nil {
			return err
		}
		err = cmdRun.Start()
		if err != nil {
			return err
		}

		buf := bufio.NewReader(stdout) // Notice that this is not in a loop
		num := 1
		for {
			line, _, _ := buf.ReadLine()
			if num > 3 {
				os.Exit(0)
			}
			num++
			if string(line) == "Trezarcoin server starting" {
				if displayOutput {
					fmt.Println("Trezarcoin server starting")
				}
				return nil
			} else {
				return errors.New("unable to start Trezarcoin server: " + string(line))
			}
		}
	}
	return nil
}

func (t *Trezarcoin) StopDaemon(ip, port, rpcUser, rpcPassword string, displayOut bool) (models.GenericResponse, error) {
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

func (t Trezarcoin) unarchiveFile(fullFilePath, location string) error {
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
