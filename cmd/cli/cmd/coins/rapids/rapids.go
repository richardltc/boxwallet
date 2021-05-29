package bend

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/mholt/archiver"
	"io/ioutil"
	"net/http"
	"os"
	"os/exec"
	"os/user"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/fileutils"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/rjminternet"
	"runtime"
	"strings"
	"time"

	"github.com/theckman/yacspin"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
)

const (
	cCoinName       string = "Rapids"
	cCoinNameAbbrev string = "RPD"

	cCoreVersion string = "4.0.5"

	//CDFRapidsFileRPi   string = "Rapids-" + CRapidsCoreVersion + "-arm64.tar.gz"
	cDownloadFileLin string = "Rapids-" + cCoreVersion + "-Linux.zip"
	cDownloadFileWin string = "Rapids-" + cCoreVersion + "-Windows.zip"

	cExtractedDirLin = "Rapids-" + cCoreVersion + "-Linux/"
	//CRapidsExtractedDirDaemon  = "Rapids-" + CRapidsCoreVersion + "-daemon-ubuntu1804" + "/"
	cExtractedDirWin = "rapids-" + cCoreVersion + "-win64" + "\\"

	cDownloadURL string = "https://github.com/RapidsOfficial/Rapids/releases/download/" + cCoreVersion + "/"

	cHomeDirLin string = ".rapids"
	cHomeDirWin string = "RAPIDS"

	cConfFile      string = "rapids.conf"
	cCliFileLin    string = "rapids-cli"
	cCliFileWin    string = "rapids-cli.exe"
	cDaemonFileLin string = "rapidsd"
	cDaemonFileWin string = "rapidsd.exe"
	cTxFileLin     string = "rapids-tx"
	cTxFileWin     string = "rapids-tx.exe"

	cRPCUser string = "rapidsrpc"
	cRPCPort string = "28732"

	cTipAddress string = "RvxCvM2VWVKq2iSLNoAmzdqH4eF9bhvn6k"

	cUtfTick     string = "\u2713"
	CUtfTickBold string = "\u2714"
)

type WEType int

const (
	WETUnencrypted WEType = iota
	WETLocked
	WETUnlocked
	WETUnlockedForStaking
	WETUnknown
)

type Rapids struct {
	RPCUser     string
	RPCPassword string
	IPAddress   string
	Port        string
}

var lastBCSyncPos float64

func (r Rapids) Bootstrap(rpcUser, rpcPassword, ip, port string) {
	r.RPCUser = rpcUser
	r.RPCPassword = rpcPassword
	r.IPAddress = ip
	r.Port = port
}

func (r Rapids) AddNodesAlreadyExist() (bool, error) {
	var exists bool

	exists, err := fileutils.StringExistsInFile("addnode=", r.HomeDir()+cConfFile)
	if err != nil {
		return false, nil
	}

	if exists {
		return true, nil
	}
	return false, nil
}

func (r Rapids) AllBinaryFilesExist(dir string) (bool, error) {
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

func (r Rapids) ConfFile() string {
	return cConfFile
}

func (r Rapids) CoinName() string {
	return cCoinName
}

func (r Rapids) CoinNameAbbrev() string {
	return cCoinNameAbbrev
}

func (r Rapids) DaemonFilename() string {
	if runtime.GOOS == "windows" {
		return cDaemonFileWin
	}

	return cDaemonFileLin
}

// DownloadCoin - Downloads the Syscoin files into the spcified location.
// "location" should just be the AppBinaryFolder ~/.boxwallet
func (r Rapids) DownloadCoin(location string) error {
	var fullFilePath, fullFileDLURL string

	switch runtime.GOOS {
	case "windows":
		fullFilePath = location + cDownloadFileWin
		fullFileDLURL = cDownloadURL + cDownloadFileWin
	case "linux":
		switch runtime.GOARCH {
		case "arm":
			return errors.New("arm32 is not currently supported for " + cCoinName)
		case "arm64":
			return errors.New("arm64 is not currently supported for " + cCoinName)
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
	if err := r.unarchiveFile(fullFilePath, location); err != nil {
		return err
	}
	return nil
}

func getRapidsAddNodes() ([]byte, error) {
	addnodes := []byte("addnode=104.248.62.138:28732\n" +
		"addnode=108.61.189.250:58678\n" +
		"addnode=138.197.145.38:28732\n" +
		"addnode=142.93.157.62:55586\n" +
		"addnode=144.91.117.147:28732\n" +
		"addnode=145.239.64.148:28732\n" +
		"addnode=159.203.22.189:33890\n" +
		"addnode=159.89.94.245:28732\n" +
		"addnode=162.157.204.186:50753\n" +
		"addnode=165.22.104.43:46592")

	return addnodes, nil
}

func (r *Rapids) BlockchainInfo() (models.RapidsBlockchainInfo, error) {
	var respStruct models.RapidsBlockchainInfo

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getblockchaininfo\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+r.IPAddress+":"+r.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(r.RPCUser, r.RPCPassword)
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

func (r Rapids) HomeDir() string {
	if runtime.GOOS == "windows" {
		return cHomeDirWin
	} else {
		return cHomeDirLin
	}
}

func (r Rapids) HomeDirFullPath() (string, error) {
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

func (r *Rapids) Info() (models.RapidsGetInfo, error) {
	//attempts := 5
	//waitingStr := "Checking server..."

	var respStruct models.RapidsGetInfo

	for i := 1; i < 50; i++ {
		//fmt.Printf("\r"+waitingStr+" %d/"+strconv.Itoa(attempts), i)
		body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandGetInfo + "\",\"params\":[]}")
		req, err := http.NewRequest("POST", "http://"+r.IPAddress+":"+r.Port, body)
		if err != nil {
			return respStruct, err
		}
		req.SetBasicAuth(r.RPCUser, r.RPCPassword)
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
			time.Sleep(5 * time.Second)
		} else {

			_ = json.Unmarshal(bodyResp, &respStruct)
			return respStruct, err
		}
	}
	return respStruct, nil
}

// Install - Puts the freshly downloaded files into their correct location.
// "location" should just be the AppBinaryFolder ~/.boxwallet
func (r Rapids) Install(location string) error {

	// Copy files to correct location
	var srcPath, sfCLI, sfD, dirToRemove1, dirToRemove2 string

	switch runtime.GOOS {
	case "windows":
		srcPath = location + cDownloadFileWin
		sfCLI = cCliFileWin
		sfD = cDaemonFileWin
	case "linux":
		switch runtime.GOARCH {
		case "arm", "arm64":
			srcPath = location + cExtractedDirLin
			sfCLI = cCliFileLin
			sfD = cDaemonFileLin
			dirToRemove1 = location + cExtractedDirLin
			dirToRemove2 = location + "__MACOSX"
		case "amd64":
			srcPath = location + cExtractedDirLin
			sfCLI = cCliFileLin
			sfD = cDaemonFileLin
			dirToRemove1 = location + cExtractedDirLin
			dirToRemove2 = location + "__MACOSX"
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

	_ = os.RemoveAll(dirToRemove1)
	_ = os.RemoveAll(dirToRemove2)

	return nil
}

func (r *Rapids) InfoUI(spin *yacspin.Spinner) (models.RapidsGetInfo, string, error) {
	var respStruct models.RapidsGetInfo

	for i := 1; i < 600; i++ {
		body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandGetInfo + "\",\"params\":[]}")
		req, err := http.NewRequest("POST", "http://"+r.IPAddress+":"+r.Port, body)
		if err != nil {
			return respStruct, "", err
		}
		req.SetBasicAuth(r.RPCUser, r.RPCPassword)
		req.Header.Set("Content-Type", "text/plain;")

		for j := 1; j < 60; j++ {
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				spin.Message(" waiting for your " + cCoinName + " wallet to respond, this could take several minutes (ctrl-c to cancel)...")
				time.Sleep(1 * time.Second)
				continue
			}
			defer resp.Body.Close()
			bodyResp, err := ioutil.ReadAll(resp.Body)
			if err != nil {
				return respStruct, "", err
			}

			// Check to make sure we are not loading the wallet
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
					spin.Message(" Your " + cCoinName + " wallet is currently Loading, this could take several minutes...")
				} else if bytes.Contains(bodyResp, []byte("Rescanning")) {
					spin.Message(" Your " + cCoinName + " wallet is currently Rescanning, this could take several minutes...")
				} else if bytes.Contains(bodyResp, []byte("Rewinding")) {
					spin.Message(" Your " + cCoinName + " wallet is currently Rewinding, this could take several minutes...")
				} else if bytes.Contains(bodyResp, []byte("Verifying")) {
					spin.Message(" Your " + cCoinName + " wallet is currently Verifying, this could take several minutes...")
				} else if bytes.Contains(bodyResp, []byte("Calculating money supply")) {
					spin.Message(" Your " + cCoinName + " wallet is currently Calculating money supply, this could take several minutes...")
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

func (r *Rapids) MNSyncStatus() (models.RapidsMNSyncStatus, error) {
	var respStruct models.RapidsMNSyncStatus

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"mnsync\",\"params\":[\"status\"]}")
	req, err := http.NewRequest("POST", "http://"+r.IPAddress+":"+r.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(r.RPCUser, r.RPCPassword)
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

// func (r *Rapids) GetNetworkBlocksTxt(bci *models.RapidsBlockchainInfo) string {
// 	blocksStr := humanize.Comma(int64(bci.Result.Blocks))

// 	if bci.Result.Blocks > 100 {
// 		return "Blocks:      [" + blocksStr + "](fg:green)"
// 	} else {
// 		return "[Blocks:      " + blocksStr + "](fg:red)"
// 	}
// }

// func (r *Rapids) GetNetworkConnectionsTxt(connections int) string {
// 	if connections == 0 {
// 		return "Peers:       [0](fg:red)"
// 	}
// 	return "Peers:       [" + strconv.Itoa(connections) + "](fg:green)"
// }

// func (r *Rapids) NetworkDifficultyTxt(difficulty, good, warn float64) string {
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

// func (r *Rapids) BlockchainSyncTxt(synced bool, bci *models.RapidsBlockchainInfo) (txt string) {
// 	s := convertBCVerification(bci.Result.Verificationprogress)
// 	if s == "0.0" {
// 		s = ""
// 	} else {
// 		s = s + "%"
// 	}

// 	if !synced {
// 		if bci.Result.Verificationprogress > lastBCSyncPos {
// 			lastBCSyncPos = bci.Result.Verificationprogress
// 			return "Blockchain:  [syncing " + s + " ](fg:yellow)"
// 		} else {
// 			lastBCSyncPos = bci.Result.Verificationprogress
// 			return "Blockchain:  [waiting " + s + " ](fg:yellow)"
// 		}
// 	} else {
// 		return "Blockchain:  [synced " + CUtfTickBold + "](fg:green)"
// 	}
// }

func (r Rapids) RPCDefaultUsername() string {
	return cRPCUser
}

func (r Rapids) RPCDefaultPort() string {
	return cRPCPort
}

func (r *Rapids) StakingStatus() (models.RapidsStakingStatus, error) {
	var respStruct models.RapidsStakingStatus

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getstakingstatus\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+r.IPAddress+":"+r.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(r.RPCUser, r.RPCPassword)
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

func (r Rapids) TipAddress() string {
	return cTipAddress
}

func (r *Rapids) WalletInfo() (models.RapidsWalletInfo, error) {
	var respStruct models.RapidsWalletInfo

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getwalletinfo\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+r.IPAddress+":"+r.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(r.RPCUser, r.RPCPassword)
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

func (r Rapids) WalletSecurityState() (models.WEType, error) {
	wi, err := r.WalletInfo()
	if err != nil {
		return models.WETUnknown, errors.New("Unable to WalletSecurityState: " + err.Error())
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

func (r *Rapids) ListReceivedByAddress(includeZero bool) (models.RapidsListReceivedByAddress, error) {
	var respStruct models.RapidsListReceivedByAddress

	var s string
	if includeZero {
		s = "{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"listreceivedbyaddress\",\"params\":[1, true]}"
	} else {
		s = "{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"listreceivedbyaddress\",\"params\":[1, false]}"
	}
	body := strings.NewReader(s)
	req, err := http.NewRequest("POST", "http://"+r.IPAddress+":"+r.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(r.RPCUser, r.RPCPassword)
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

func (r *Rapids) StartDaemon(displayOutput bool) error {
	if runtime.GOOS == "windows" {
		fp := cHomeDirWin + cDaemonFileWin
		cmd := exec.Command("cmd.exe", "/C", "start", "/b", fp)
		if err := cmd.Run(); err != nil {
			return err
		}
	} else {
		if displayOutput {
			fmt.Println("Attempting to run the rapidsd daemon...")
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

		// Wait a few seconds before reading the output...
		time.Sleep(3 * time.Second)
		buf := bufio.NewReader(stdout)
		num := 1
		//bStarting := false
		//sIssue := ""
		for {
			line, _, _ := buf.ReadLine()
			if num > 10 {
				os.Exit(0)
			}
			num++
			//if string(line) == "RPD server starting" {
			//	bStarting = true
			//	}
			//if string(line) == "RPD server starting" {
			//	bStarting = true
			//}

			if string(line) == "RPD server starting" {
				if displayOutput {
					fmt.Println("Rapids server is starting...")
				}
				return nil
			} else {
				return errors.New("unable to start the Rapids server: " + string(line))
			}
		}
	}
	return nil
}

func (r *Rapids) StopDaemon(ip, port, rpcUser, rpcPassword string, displayOut bool) (models.GenericResponse, error) {
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

func (r Rapids) unarchiveFile(fullFilePath, location string) error {
	if err := archiver.Unarchive(fullFilePath, location); err != nil {
		return fmt.Errorf("unable to unarchive file: %v - %v", fullFilePath, err)
	}
	switch runtime.GOOS {
	case "windows":
		defer os.RemoveAll(location + cDownloadFileWin)
	case "linux":
		switch runtime.GOARCH {
		case "arm":
			return errors.New("arm32 is not currently supported for :" + cCoinName)
		case "arm64":
			return errors.New("arm64 is not currently supported for :" + cCoinName)
		case "386":
			return errors.New("linux 386 is not currently supported for :" + cCoinName)
		case "amd64":
			defer os.RemoveAll(location + cDownloadFileLin)
		}
	}

	defer os.Remove(fullFilePath)

	return nil
}

func (r *Rapids) UnlockWalletRapids(pw string) error {
	var respStruct models.GenericResponse

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"walletpassphrase\",\"params\":[\"" + pw + "\",0]}")
	req, err := http.NewRequest("POST", "http://"+r.IPAddress+":"+r.Port, body)
	if err != nil {
		return err
	}
	req.SetBasicAuth(r.RPCUser, r.RPCPassword)
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

// // convertBCVerification - Convert Blockchain verification progress...
// func convertBCVerification(verificationPG float64) string {
// 	var sProg string
// 	var fProg float64

// 	fProg = verificationPG * 100
// 	sProg = fmt.Sprintf("%.2f", fProg)

// 	return sProg
// }
