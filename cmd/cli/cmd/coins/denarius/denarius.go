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
	"runtime"
	"strings"
	"time"

	"github.com/mholt/archiver"
	"github.com/theckman/yacspin"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/coins"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/rjminternet"
)

const (
	cCoinName       string = "Denarius"
	cCoinNameAbbrev string = "D"

	cCoreVersion string = "3.3.9.11"
	//CDFRPiDenarius       string = "Denarius-" + CDenariusCoreVersion + "-arm-linux-gnueabihf.tar.gz"
	//CDFLinuxDenarius     string = "Denarius-" + CDenariusCoreVersion + "-x86_64-linux-gnu.tar.gz"
	cDownloadFileWindows string = "Denarius-" + cCoreVersion + "-Win64.zip"
	cDownloadFileBS      string = "chaindata.zip"
	cDownloadFileBSARM   string = "pichaindata.zip"

	//CDenariusExtractedDirLinux   = "Denarius-" + CDenariusCoreVersion + "/"
	cExtractedDirWindows = "Denarius-" + cCoreVersion + "\\"

	cDownloadURL   string = "https://github.com/carsenk/denarius/releases/download/v" + cCoreVersion + "/"
	cDownloadURLBS string = "https://denarii.cloud/"

	cBinDirLinux string = "/snap/bin/"
	cHomeDirLin  string = "snap/denarius/common/.denarius"
	cHomeDirWin  string = "denarius"

	cTipAddress string = "DNxQWmq3JocvccZNcEGPpztB87GMEd3XVi"

	// Files
	cConfFile      string = "denarius.conf"
	cCliFile       string = "denarius"
	cCliFileWin    string = "denarius-cli.exe"
	cDaemonFile    string = "denarius.daemon"
	cDaemonMem     string = "denariusd"
	cDaemonFileWin string = "denarius.daemon.exe"
	cTxFile        string = "denarius-tx"
	cTxFileWin     string = "denarius-tx.exe"

	// Networking
	cRPCUser string = "denariusrpc"
	cRPCPort string = "32369"

	cCommandGetBCInfo             string = "getblockchaininfo"
	cCommandGetInfo               string = "getinfo"
	cCommandGetStakingInfo        string = "getstakinginfo"
	cCommandListReceivedByAddress string = "listreceivedbyaddress"
	cCommandListTransactions      string = "listtransactions"
	cCommandGetNetworkInfo        string = "getnetworkinfo"
	cCommandGetNewAddress         string = "getnewaddress"
	cCommandGetWalletInfo         string = "getwalletinfo"
	cCommandSendToAddress         string = "sendtoaddress"
	cCommandMNSyncStatus1         string = "mnsync"
	cCommandMNSyncStatus2         string = "status"
	cCommandDumpHDInfo            string = "dumphdinfo" // ./divi-cli dumphdinfo

)

type Denarius struct {
	RPCUser     string
	RPCPassword string
	IPAddress   string
	Port        string
}

func (d Denarius) BootStrap(rpcUser, rpcPassword, ip, port string) {
	d.RPCUser = rpcUser
	d.RPCPassword = rpcPassword
	d.IPAddress = ip
	d.Port = port
}

func (d *Denarius) AbbreviatedCoinName() string {
	return cCoinNameAbbrev
}

func (d Denarius) AllBinaryFilesExist(dir string) (bool, error) {
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
		if !fileExists(dir + cCliFile) {
			return false, nil
		}
		if !fileExists(dir + cDaemonFile) {
			return false, nil
		}
		if !fileExists(dir + cTxFile) {
			return false, nil
		}
	}
	return true, nil
}

// BlockchainDataExists - Returns true if the Blockchain data exists for the specified coin.
func (d Denarius) BlockchainDataExists() (bool, error) {
	coinDir, err := d.HomeDirFullPath()
	if err != nil {
		return false, errors.New("unable to HomeDirFullPath - BlockchainDataExists")
	}

	// If the "blk0001.dat" file already exists, return.
	if _, err := os.Stat(coinDir + "blk0001.dat"); !os.IsNotExist(err) {
		err := errors.New("The file: " + coinDir + "blk0001.dat already exists")
		return true, err
	}

	// If the "blk0002.dat" file already exists, return
	if _, err := os.Stat(coinDir + "blk0002.dat"); !os.IsNotExist(err) {
		err := errors.New("The file: " + coinDir + "blk0002.dat already exists")
		return true, err
	}
	return false, nil
}

func (d Denarius) ConfFile() string {
	return cConfFile
}

func (d Denarius) CoinName() string {
	return cCoinName
}

func (d Denarius) CoinNameAbbrev() string {
	return cCoinNameAbbrev
}

func (d *Denarius) DaemonFilename() string {
	if runtime.GOOS == "windows" {
		return cDaemonFileWin
	} else {
		return cDaemonFile
	}
}

func (d Denarius) DownloadBlockchain() error {
	var coinDir string
	var err error

	// First, check to make sure that both the blockchain folders don't already exist. (blocks, chainstate)
	coinDir, err = d.HomeDirFullPath()
	if err != nil {
		return errors.New("unable to GetCoinHomeFolder")
	}
	switch runtime.GOARCH {
	case "arm", "arm64":
		bcsFileExists := coins.FileExists(coinDir + cDownloadFileBSARM)
		if !bcsFileExists {
			// Then download the file.
			if err := rjminternet.DownloadFile(coinDir, cDownloadURLBS+cDownloadFileBSARM); err != nil {
				return errors.New("unable to download file: - " + cDownloadFileBSARM)
			}
		}
	default:
		bcsFileExists := coins.FileExists(coinDir + cDownloadFileBS)
		if !bcsFileExists {
			// Then download the file.
			if err := rjminternet.DownloadFile(coinDir, cDownloadURLBS+cDownloadFileBS); err != nil {
				return errors.New("unable to download file: - " + cDownloadFileBS)
			}
		}
	}
	return nil
}

func (d Denarius) DownloadCoin(location string) error {
	// This is just here to satisfy the Coin interface.

	return nil
}

func (d *Denarius) BlockchainInfo() (models.DenariusBlockchainInfo, error) {
	var respStruct models.DenariusBlockchainInfo

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getblockchaininfo\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+d.IPAddress+":"+d.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(d.RPCUser, d.RPCPassword)
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

func (d *Denarius) GetInfo() (models.DenariusGetInfo, error) {
	var respStruct models.DenariusGetInfo

	for i := 1; i < 50; i++ {
		//fmt.Printf("\r"+waitingStr+" %d/"+strconv.Itoa(attempts), i)
		body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + cCommandGetInfo + "\",\"params\":[]}")
		req, err := http.NewRequest("POST", "http://"+d.IPAddress+":"+d.Port, body)
		if err != nil {
			return respStruct, err
		}
		req.SetBasicAuth(d.RPCUser, d.RPCPassword)
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

func (d *Denarius) GetStakingInfo() (models.DenariusStakingInfoS, error) {
	var respStruct models.DenariusStakingInfoS

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + cCommandGetStakingInfo + "\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+d.IPAddress+":"+d.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(d.RPCUser, d.RPCPassword)
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

func (d *Denarius) GetInfoUI(spin *yacspin.Spinner) (models.DenariusGetInfo, string, error) {
	var respStruct models.DenariusGetInfo

	for i := 1; i < 600; i++ {
		body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + cCommandGetInfo + "\",\"params\":[]}")
		req, err := http.NewRequest("POST", "http://"+d.IPAddress+":"+d.Port, body)
		if err != nil {
			return respStruct, "", err
		}
		req.SetBasicAuth(d.RPCUser, d.RPCPassword)
		req.Header.Set("Content-Type", "text/plain;")

		resp, err := http.DefaultClient.Do(req)
		//defer resp.Body.Close()
		if err != nil {
			spin.Message(" waiting for your " + cCoinName + " wallet to respond, this could take several minutes (ctrl-c to cancel)...")
			time.Sleep(1 * time.Second)
		} else {
			defer resp.Body.Close()
			bodyResp, err := ioutil.ReadAll(resp.Body)
			if err != nil {
				return respStruct, "", err
			}

			// Check to make sure we are not loading the wallet.
			if bytes.Contains(bodyResp, []byte("Loading")) ||
				bytes.Contains(bodyResp, []byte("Rescanning")) ||
				bytes.Contains(bodyResp, []byte("Rewinding")) ||
				bytes.Contains(bodyResp, []byte("RPC in warm-up: Calculating money supply")) ||
				bytes.Contains(bodyResp, []byte("Verifying")) {
				// The wallet is still loading, so print message, and sleep for 1 second and try again..
				var errStruct models.GenericResponse
				err = json.Unmarshal(bodyResp, &errStruct)
				if err != nil {
					return respStruct, "", err
				}

				if bytes.Contains(bodyResp, []byte("Loading")) {
					spin.Message(" Your " + cCoinName + " wallet is *Loading*, this could take a while...")
				} else if bytes.Contains(bodyResp, []byte("Rescanning")) {
					spin.Message(" Your " + cCoinName + " wallet is *Rescanning*, this could take a while...")
				} else if bytes.Contains(bodyResp, []byte("Rewinding")) {
					spin.Message(" Your " + cCoinName + " wallet is *Rewinding*, this could take a while...")
				} else if bytes.Contains(bodyResp, []byte("Verifying")) {
					spin.Message(" Your " + cCoinName + " wallet is *Verifying*, this could take a while...")
				} else if bytes.Contains(bodyResp, []byte("Calculating money supply")) {
					spin.Message(" Your " + cCoinName + " wallet is *Calculating money supply*, this could take a while...")
				}
				time.Sleep(1 * time.Second)
			} else {
				_ = json.Unmarshal(bodyResp, &respStruct)
				return respStruct, string(bodyResp), err
			}
		}
	}
	return respStruct, "", nil
}

func (d *Denarius) GetNewAddress() (models.DenariusNewAddress, error) {
	var respStruct models.DenariusNewAddress

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getnewaddress\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+d.IPAddress+":"+d.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(d.RPCUser, d.RPCPassword)
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

func (d *Denarius) GetWalletSecurityState(gi *models.DenariusGetInfo) models.WEType {
	if gi.Result.UnlockedUntil == 0 {
		return models.WETLocked
	} else if gi.Result.UnlockedUntil == -1 {
		return models.WETUnencrypted
	} else if gi.Result.UnlockedUntil > 0 {
		return models.WETUnlockedForStaking
	} else {
		return models.WETUnknown
	}
}

func (d Denarius) HomeDir() string {
	if runtime.GOOS == "windows" {
		return cHomeDirWin
	} else {
		return cHomeDirLin
	}
}

func (d Denarius) HomeDirFullPath() (string, error) {
	u, err := user.Current()
	if err != nil {
		return "", err
	}
	hd := u.HomeDir

	if runtime.GOOS == "windows" {
		return addTrailingSlash(hd) + "appdata\\roaming\\" + addTrailingSlash(cHomeDirWin), nil
	} else {
		return addTrailingSlash(hd) + addTrailingSlash(cHomeDirLin), nil
	}
}

func (d Denarius) Install(location string) error {
	// Just here to satisfy Interface.

	return nil
}

func (d *Denarius) ListReceivedByAddress(includeZero bool) (models.DenariusListReceivedByAddress, error) {
	var respStruct models.DenariusListReceivedByAddress

	var s string
	if includeZero {
		s = "{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"listreceivedbyaddress\",\"params\":[1, true]}"
	} else {
		s = "{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"listreceivedbyaddress\",\"params\":[1, false]}"
	}
	body := strings.NewReader(s)
	req, err := http.NewRequest("POST", "http://"+d.IPAddress+":"+d.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(d.RPCUser, d.RPCPassword)
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

func (d *Denarius) ListTransactions() (models.DenariusListTransactions, error) {
	var respStruct models.DenariusListTransactions

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + cCommandListTransactions + "\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+d.IPAddress+":"+d.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(d.RPCUser, d.RPCPassword)
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

func (d *Denarius) StartDaemon(displayOutput bool) error {
	if runtime.GOOS == "windows" {
		fp := cHomeDirWin + cDaemonFileWin
		cmd := exec.Command("cmd.exe", "/C", "start", "/b", fp)
		if err := cmd.Run(); err != nil {
			return err
		}
	} else {
		if displayOutput {
			fmt.Println("Attempting to run the denariusd daemon...")
		}

		cmdRun := exec.Command(cBinDirLinux + cDaemonFile)
		//stdout, err := cmdRun.StdoutPipe()
		err := cmdRun.Start()
		if err != nil {
			return err
		}
		if displayOutput {
			fmt.Println("Denarius server starting")
		}

	}
	return nil
}

func (d *Denarius) StopDaemon(displayOut bool) (models.GenericResponse, error) {
	var respStruct models.GenericResponse

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"stop\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+d.IPAddress+":"+d.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(d.RPCUser, d.RPCPassword)
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

func (d Denarius) TipAddress() string {
	return cTipAddress
}

func (d Denarius) UnarchiveBlockchainSnapshot() error {
	coinDir, err := d.HomeDirFullPath()
	if err != nil {
		return errors.New("unable to get HomeDirFul - " + err.Error())
	}

	// First, check to make sure that both the blockchain folders don't already exist. (blocks, chainstate)
	chdExists, err := d.BlockchainDataExists()
	if err != nil {
		return fmt.Errorf("unable to determine if BlockchainDataExists: %v", err)
	}
	if chdExists {
		err := errors.New("blockchain data already exists")
		return err
	}
	switch runtime.GOARCH {
	case "arm", "arm64":
		bcsFileExists := coins.FileExists(coinDir + cDownloadFileBSARM)
		if !bcsFileExists {
			return errors.New("unable to find the snapshot file: " + coinDir + cDownloadFileBSARM)
		}

		// Now extract it straight into the Denarius home dir
		fmt.Println("Decompressing to " + coinDir + "...")
		if err := archiver.Unarchive(coinDir+cDownloadFileBSARM, coinDir); err != nil {
			return errors.New("unable to unarchive file: " + coinDir + cDownloadFileBSARM)
		}
	default:
		bcsFileExists := coins.FileExists(coinDir + cDownloadFileBS)
		if !bcsFileExists {
			return errors.New("unable to find the snapshot file: " + coinDir + cDownloadFileBS)
		}

		// Now extract it straight into the Denarius home folder
		if err := archiver.Unarchive(coinDir+cDownloadFileBS, coinDir); err != nil {
			return fmt.Errorf("unable to unarchive file: %v - %v", coinDir+cDownloadFileBS, err)
		}
	}
	return nil
}

func (d *Denarius) WalletSecurityState() (models.WEType, error) {
	info, err := d.GetInfo()
	if err != nil {
		return models.WETUnknown, errors.New("Unable to GetWalletSecurityState: " + err.Error())
	}

	if info.Result.UnlockedUntil == 0 {
		return models.WETLocked, nil
	} else if info.Result.UnlockedUntil == -1 {
		return models.WETUnencrypted, nil
	} else if info.Result.UnlockedUntil > 0 {
		return models.WETUnlockedForStaking, nil
	} else {
		return models.WETUnknown, nil
	}
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

func fileExists(filename string) bool {
	info, err := os.Stat(filename)
	if os.IsNotExist(err) {
		return false
	}
	return !info.IsDir()
}
