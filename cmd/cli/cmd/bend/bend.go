package bend

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/AlecAivazis/survey/v2"
	"io/ioutil"
	"log"
	"net/http"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/mitchellh/go-ps"
	gwc "github.com/richardltc/gwcommon"
	rand "richardmace.co.uk/boxdivi/cmd/cli/cmd/bend/rand"
)

const (
	cDiviAddNodeURL string = "https://api.diviproject.org/v1/addnode"

	// Divi-cli command constants
	cCommandGetBCInfo     string = "getblockchaininfo"
	cCommandGetWInfo      string = "getwalletinfo"
	cCommandMNSyncStatus1 string = "mnsync"
	cCommandMNSyncStatus2 string = "status"

	// Divi-cli wallet commands
	cCommandDisplayWalletAddress string = "getaddressesbyaccount" // ./divi-cli getaddressesbyaccount ""
	cCommandDumpHDInfo           string = "dumphdinfo"            // ./divi-cli dumphdinfo
	// CCommandEncryptWallet - Needed by dash command
	CCommandEncryptWallet  string = "encryptwallet"    // ./divi-cli encryptwallet “a_strong_password”
	cCommandRestoreWallet  string = "-hdseed="         // ./divid -debug-hdseed=the_seed -rescan (stop divid, rename wallet.dat, then run command)
	cCommandUnlockWallet   string = "walletpassphrase" // ./divi-cli walletpassphrase “password” 0
	cCommandUnlockWalletFS string = "walletpassphrase" // ./divi-cli walletpassphrase “password” 0 true
	cCommandLockWallet     string = "walletlock"       // ./divi-cli walletlock

	cRPCUserStr     string = "rpcuser"
	cRPCPasswordStr string = "rpcpassword"
)

//type blockChainInfo struct {
//	Chain                string  `json:"chain"`
//	Blocks               int     `json:"blocks"`
//	Headers              int     `json:"headers"`
//	Bestblockhash        string  `json:"bestblockhash"`
//	Difficulty           float64 `json:"difficulty"`
//	Verificationprogress float64 `json:"verificationprogress"`
//	Chainwork            string  `json:"chainwork"`
//}

type BlockchainInfoRespStruct struct {
	Result struct {
		Chain                string  `json:"chain"`
		Blocks               int     `json:"blocks"`
		Headers              int     `json:"headers"`
		Bestblockhash        string  `json:"bestblockhash"`
		Difficulty           float64 `json:"difficulty"`
		Verificationprogress float64 `json:"verificationprogress"`
		Chainwork            string  `json:"chainwork"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type GenericRespStruct struct {
	Result string      `json:"result"`
	Error  interface{} `json:"error"`
	ID     string      `json:"id"`
}

type GetAddressesByAccountRespStruct struct {
	Result []string    `json:"result"`
	Error  interface{} `json:"error"`
	ID     string      `json:"id"`
}

type GetInfoRespStruct struct {
	Result struct {
		Version         string  `json:"version"`
		Protocolversion int     `json:"protocolversion"`
		Walletversion   int     `json:"walletversion"`
		Balance         float64 `json:"balance"`
		Blocks          int     `json:"blocks"`
		Timeoffset      int     `json:"timeoffset"`
		Connections     int     `json:"connections"`
		Proxy           string  `json:"proxy"`
		Difficulty      float64 `json:"difficulty"`
		Testnet         bool    `json:"testnet"`
		Moneysupply     float64 `json:"moneysupply"`
		Keypoololdest   int     `json:"keypoololdest"`
		Keypoolsize     int     `json:"keypoolsize"`
		UnlockedUntil   int     `json:"unlocked_until"`
		Paytxfee        float64 `json:"paytxfee"`
		Relayfee        float64 `json:"relayfee"`
		StakingStatus   string  `json:"staking status"`
		Errors          string  `json:"errors"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type LotteryRespStruct struct {
	Lottery struct {
		AverageBlockTime float64 `json:"averageBlockTime"`
		CurrentBlock     int     `json:"currentBlock"`
		NextLotteryBlock int     `json:"nextLotteryBlock"`
		Countdown        struct {
			Milliseconds float64 `json:"milliseconds"`
			Humanized    string  `json:"humanized"`
		} `json:"countdown"`
	} `json:"lottery"`
	Stats string `json:"stats"`
}

type StakingStatusRespStruct struct {
	Result struct {
		Validtime       bool `json:"validtime"`
		Haveconnections bool `json:"haveconnections"`
		Walletunlocked  bool `json:"walletunlocked"`
		Mintablecoins   bool `json:"mintablecoins"`
		Enoughcoins     bool `json:"enoughcoins"`
		Mnsync          bool `json:"mnsync"`
		StakingStatus   bool `json:"staking status"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type WalletInfoRespStruct struct {
	Result struct {
		Walletversion      int     `json:"walletversion"`
		Balance            float64 `json:"balance"`
		UnconfirmedBalance float64 `json:"unconfirmed_balance"`
		ImmatureBalance    float64 `json:"immature_balance"`
		Txcount            int     `json:"txcount"`
		Keypoololdest      int     `json:"keypoololdest"`
		Keypoolsize        int     `json:"keypoolsize"`
		EncryptionStatus   string  `json:"encryption_status"`
		Hdchainid          string  `json:"hdchainid"`
		Hdaccountcount     int     `json:"hdaccountcount"`
		Hdaccounts         []struct {
			Hdaccountindex     int `json:"hdaccountindex"`
			Hdexternalkeyindex int `json:"hdexternalkeyindex"`
			Hdinternalkeyindex int `json:"hdinternalkeyindex"`
		} `json:"hdaccounts"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type MNSyncStatusRespStruct struct {
	Result struct {
		IsBlockchainSynced         bool `json:"IsBlockchainSynced"`
		LastMasternodeList         int  `json:"lastMasternodeList"`
		LastMasternodeWinner       int  `json:"lastMasternodeWinner"`
		LastFailure                int  `json:"lastFailure"`
		NCountFailures             int  `json:"nCountFailures"`
		SumMasternodeList          int  `json:"sumMasternodeList"`
		SumMasternodeWinner        int  `json:"sumMasternodeWinner"`
		CountMasternodeList        int  `json:"countMasternodeList"`
		CountMasternodeWinner      int  `json:"countMasternodeWinner"`
		RequestedMasternodeAssets  int  `json:"RequestedMasternodeAssets"`
		RequestedMasternodeAttempt int  `json:"RequestedMasternodeAttempt"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type privateSeedStruct struct {
	Hdseed             string `json:"hdseed"`
	Mnemonic           string `json:"mnemonic"`
	Mnemonicpassphrase string `json:"mnemonicpassphrase"`
}

type listTransactions []struct {
	Account         string        `json:"account"`
	Address         string        `json:"address"`
	Category        string        `json:"category"`
	Amount          float64       `json:"amount"`
	Vout            int           `json:"vout"`
	Confirmations   int           `json:"confirmations"`
	Bcconfirmations int           `json:"bcconfirmations"`
	Blockhash       string        `json:"blockhash"`
	Blockindex      int           `json:"blockindex"`
	Blocktime       int           `json:"blocktime"`
	Txid            string        `json:"txid"`
	Walletconflicts []interface{} `json:"walletconflicts"`
	Time            int           `json:"time"`
	Timereceived    int           `json:"timereceived"`
}

type stakingStatusStruct struct {
	Validtime       bool `json:"validtime"`
	Haveconnections bool `json:"haveconnections"`
	Walletunlocked  bool `json:"walletunlocked"`
	Mintablecoins   bool `json:"mintablecoins"`
	Enoughcoins     bool `json:"enoughcoins"`
	Mnsync          bool `json:"mnsync"`
	StakingStatus   bool `json:"staking status"`
}

type walletResponseType int

const (
	wrType walletResponseType = iota
	wrtUnknown
	wrtAllOK
	wrtNotReady
	wrtStillLoading
)

type WalletFixType int

const (
	WFType WalletFixType = iota
	WFTReIndex
	WFTReSync
)

func AddNodesAlreadyExist() (bool, error) {
	gwconf, err := gwc.GetCLIConfStruct()
	if err != nil {
		return false, fmt.Errorf("unable to GetConfigStruct - %v", err)
	}
	switch gwconf.ProjectType {
	case gwc.PTDivi:
		chd, _ := gwc.GetCoinHomeFolder(gwc.APPTCLI)

		exists, err := gwc.StringExistsInFile("addnode=", chd+gwc.CDiviConfFile)
		if err != nil {
			return false, nil
		}
		if exists {
			return true, nil
		}
	case gwc.PTTrezarcoin:
	default:
		err = errors.New("unable to determine ProjectType")
	}
	return false, nil
}

func AddAddNodesIfRequired() error {
	doExist, err := AddNodesAlreadyExist()
	if err != nil {
		return err
	}
	if !doExist {
		gwconf, err := gwc.GetCLIConfStruct()
		if err != nil {
			return fmt.Errorf("unable to GetConfigStruct - %v", err)
		}
		switch gwconf.ProjectType {
		case gwc.PTDivi:
			chd, _ := gwc.GetCoinHomeFolder(gwc.APPTCLI)
			if err := os.MkdirAll(chd, os.ModePerm); err != nil {
				return fmt.Errorf("unable to make directory - %v", err)
			}
			addnodes, err := getAddNodes()
			if err != nil {
				return fmt.Errorf("unable to getAddNodes - %v", err)
			}

			sAddnodes := string(addnodes[:])
			if err := gwc.WriteTextToFile(chd+gwc.CDiviConfFile, sAddnodes); err != nil {
				return fmt.Errorf("unable to write addnodes to file - %v", err)
			}

		case gwc.PTTrezarcoin:

		default:
			err = errors.New("unable to determine ProjectType")
		}
	}
	return nil
}

func findProcess(key string) (int, string, error) {
	pname := ""
	pid := 0
	err := errors.New("not found")
	ps, _ := ps.Processes()

	for i := range ps {
		if ps[i].Executable() == key {
			pid = ps[i].Pid()
			pname = ps[i].Executable()
			err = nil
			break
		}
	}
	return pid, pname, err
}

func getAddNodes() ([]byte, error) {
	addNodesClient := http.Client{
		Timeout: time.Second * 3, // Maximum of 3 secs
	}

	req, err := http.NewRequest(http.MethodGet, cDiviAddNodeURL, nil)
	if err != nil {
		return nil, err
	}

	req.Header.Set("User-Agent", "boxdivi")

	res, getErr := addNodesClient.Do(req)
	if getErr != nil {
		return nil, err
	}

	body, readErr := ioutil.ReadAll(res.Body)
	if readErr != nil {
		return nil, err
	}

	return body, nil
}

//func GetPrivKey() (privateSeedStruct, walletResponseType, error) {
//	ps := privateSeedStruct{}
//
//	// Start the DiviD server if required...
//	if err := RunCoinDaemon(false); err != nil {
//		return ps, wrtUnknown, fmt.Errorf("Unable to RunDiviD: %v ", err)
//	}
//
//	dbf, err := gwc.GetAppsBinFolder(gwc.APPTServer)
//	if err != nil {
//		return ps, wrtUnknown, fmt.Errorf("Unable to GetAppsBinFolder: %v ", err)
//	}
//
//	for i := 0; i <= 4; i++ {
//		cmd := exec.Command(dbf+gwc.CDiviCliFile, cCommandDumpHDInfo)
//		var stdout bytes.Buffer
//		cmd.Stdout = &stdout
//		cmd.Run()
//		if err != nil {
//			return ps, wrtUnknown, err
//		}
//
//		outStr := string(stdout.Bytes())
//		wr := getWalletResponse(outStr)
//
//		if wr == wrtAllOK {
//			errUM := json.Unmarshal([]byte(outStr), &ps)
//			if errUM == nil {
//				return ps, wrtAllOK, err
//			}
//		}
//
//		time.Sleep(1 * time.Second)
//	}
//
//	return ps, wrtUnknown, errors.New("unable to retrieve private key")
//}

// // DoPrivKeyFile - Handles the private key
// func DoPrivKeyFile() error {
// 	dbf, err := GetAppsBinFolder()
// 	if err != nil {
// 		return fmt.Errorf("Unable to GetAppsBinFolder: %v", err)
// 	}

// 	// User specified that they wanted to save their private key in a file.
// 	s := getWalletSeedDisplayWarning() + `

// Storing your private key in a file is risky.

// Please confirm that you understand the risks: `
// 	yn := getYesNoResp(s)
// 	if yn == "y" {
// 		fmt.Println("\nRequesting private seed...")
// 		s, err := runDCCommand(dbf+cDiviCliFile, cCommandDumpHDinfo, "Waiting for wallet to respond. This could take several minutes...", 30)
// 		// cmd := exec.Command(dbf+cDiviCliFile, cCommandDumpHDinfo)
// 		// out, err := cmd.CombinedOutput()
// 		if err != nil {
// 			return fmt.Errorf("Unable to run command: %v - %v", dbf+cDiviCliFile+cCommandDumpHDinfo, err)
// 		}

// 		// Now store the info in file
// 		err = WriteTextToFile(dbf+cWalletSeedFileGoDivi, s)
// 		if err != nil {
// 			return fmt.Errorf("error writing to file %s", err)
// 		}
// 		fmt.Println("Now please store the privte seed file somewhere safe. The file has been saved to: " + dbf + cWalletSeedFileGoDivi)
// 	}
// 	return nil
// }

// func doWalletAdressDisplay() error {
// 	err := gwc.RunCoinDaemon(false)
// 	if err != nil {
// 		return fmt.Errorf("Unable to RunCoinDaemon: %v ", err)
// 	}

// 	dbf, err := gwc.GetAppsBinFolder()
// 	if err != nil {
// 		return fmt.Errorf("Unable to GetAppsBinFolder: %v", err)
// 	}
// 	// Display wallet public address

// 	fmt.Println("\nRequesting wallet address...")
// 	s, err := RunDCCommandWithValue(dbf+cDiviCliFile, cCommandDisplayWalletAddress, `""`, "Waiting for wallet to respond. This could take several minutes...", 30)
// 	if err != nil {
// 		return fmt.Errorf("Unable to run command: %v - %v", dbf+cDiviCliFile+cCommandDisplayWalletAddress, err)
// 	}

// 	fmt.Println("\nWallet address received...")
// 	fmt.Println("")
// 	println(s)

// 	return nil
// }

//func getBlockchainInfo() (blockChainInfo, error) {
//	bci := blockChainInfo{}
//	dbf, _ := gwc.GetAppsBinFolder(gwc.APPTServer)
//
//	cmdBCInfo := exec.Command(dbf+gwc.CDiviCliFile, cCommandGetBCInfo)
//	out, _ := cmdBCInfo.CombinedOutput()
//	err := json.Unmarshal([]byte(out), &bci)
//	if err != nil {
//		return bci, err
//	}
//	return bci, nil
//}

func GetBlockchainInfo(cliConf *gwc.CLIConfStruct) (BlockchainInfoRespStruct, error) {
	var respStruct BlockchainInfoRespStruct

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getblockchaininfo\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+cliConf.ServerIP+":"+cliConf.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(cliConf.RPCuser, cliConf.RPCpassword)
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

//func getMNSyncStatus() (mnSyncStatus, error) {
//	// gdConfig, err := getConfStruct("./")
//	// if err != nil {
//	// 	log.Print(err)
//	// }
//
//	mnss := mnSyncStatus{}
//	dbf, _ := gwc.GetAppsBinFolder(gwc.APPTServer)
//
//	cmdMNSS := exec.Command(dbf+gwc.CDiviCliFile, cCommandMNSyncStatus1, cCommandMNSyncStatus2)
//	out, _ := cmdMNSS.CombinedOutput()
//	err := json.Unmarshal([]byte(out), &mnss)
//	if err != nil {
//		return mnss, err
//	}
//	return mnss, nil
//}

func GetMNSyncStatus(cliConf *gwc.CLIConfStruct) (MNSyncStatusRespStruct, error) {
	var respStruct MNSyncStatusRespStruct

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"mnsync\",\"params\":[\"status\"]}")
	req, err := http.NewRequest("POST", "http://"+cliConf.ServerIP+":"+cliConf.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(cliConf.RPCuser, cliConf.RPCpassword)
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

// GetWalletAddress - Sends a "getaddressesbyaccount" to the daemon, and returns the result
func GetWalletAddress(cliConf *gwc.CLIConfStruct) (GetAddressesByAccountRespStruct, error) {
	var respStruct GetAddressesByAccountRespStruct

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getaddressesbyaccount\",\"params\":[\"\"]}")
	req, err := http.NewRequest("POST", "http://"+cliConf.ServerIP+":"+cliConf.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(cliConf.RPCuser, cliConf.RPCpassword)
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
	//fmt.Println(s)
	err = json.Unmarshal(bodyResp, &respStruct)
	if err != nil {
		return respStruct, err
	}
	return respStruct, nil
}

// func getWalletAddress(attempts int) (string, error) {
// 	var err error
// 	var s string = "waiting for wallet."
// 	dbf, _ := gwc.GetAppsBinFolder(gwc.APPTServer)
// 	app := dbf + gwc.CDiviCliFile
// 	arg1 := cCommandDisplayWalletAddress
// 	arg2 := ""

// 	for i := 0; i < attempts; i++ {

// 		cmd := exec.Command(app, arg1, arg2)
// 		out, err := cmd.CombinedOutput()

// 		if err == nil {
// 			return string(out), err
// 		}

// 		fmt.Printf("\r"+s+" %d/"+strconv.Itoa(attempts), i+1)

// 		time.Sleep(3 * time.Second)
// 	}

// 	return "", err

// }

// func GetWalletInfo(dispProgress bool) (walletInfoStruct, walletResponseType, error) {
// 	wi := walletInfoStruct{}

// 	// Start the DiviD server if required...
// 	err := RunCoinDaemon(false)
// 	if err != nil {
// 		return wi, wrtUnknown, fmt.Errorf("Unable to RunDiviD: %v ", err)
// 	}

// 	dbf, err := gwc.GetAppsBinFolder(gwc.APPTServer)
// 	if err != nil {
// 		return wi, wrtUnknown, fmt.Errorf("Unable to GetAppsBinFolder: %v ", err)
// 	}

// 	for i := 0; i <= 4; i++ {
// 		cmd := exec.Command(dbf+gwc.CDiviCliFile, cCommandGetWInfo)
// 		var stdout bytes.Buffer
// 		cmd.Stdout = &stdout
// 		cmd.Run()
// 		if err != nil {
// 			return wi, wrtUnknown, err
// 		}

// 		outStr := string(stdout.Bytes())
// 		wr := getWalletResponse(outStr)

// 		// cmd := exec.Command(dbf+gwc.CDiviCliFile, cCommandGetWInfo)
// 		// out, err := cmd.CombinedOutput()
// 		// sOut := string(out)
// 		//wr := getWalletResponse(sOut)
// 		if wr == wrtAllOK {
// 			errUM := json.Unmarshal([]byte(outStr), &wi)
// 			if errUM == nil {
// 				return wi, wrtAllOK, err
// 			}
// 		}

// 		time.Sleep(1 * time.Second)
// 	}

// 	return wi, wrtUnknown, errors.New("Unable to retrieve wallet info")
// }

func GetPasswordToEncryptWallet() string {
	for i := 0; i <= 2; i++ {
		epw1 := ""
		prompt := &survey.Password{
			Message: "Please enter a password to encrypt your wallet",
		}
		survey.AskOne(prompt, &epw1)

		epw2 := ""
		prompt2 := &survey.Password{
			Message: "Now please re-enter your password",
		}
		survey.AskOne(prompt2, &epw2)
		if epw1 != epw2 {
			fmt.Print("\nThe passwords don't match, please try again...\n")
		} else {
			return epw1
		}
	}
	return ""
	//reader := bufio.NewReader(os.Stdin)
	//for i := 0; i <= 2; i++ {
	//	fmt.Print("\nPlease enter a password to encrypt your wallet: ")
	//	epw1, _ := reader.ReadString('\n')
	//	fmt.Print("\nNow please re-enter your password: ")
	//	epw2, _ := reader.ReadString('\n')
	//	if epw1 != epw2 {
	//		fmt.Print("\nThe passwords don't match, please try again...\n")
	//	} else {
	//		s := strings.ReplaceAll(epw1, "\n", "")
	//
	//		return s
	//	}
	//}
	//return ""
}

func GetWalletEncryptionPassword() string {
	pword := ""
	prompt := &survey.Password{
		Message: "Please enter your encrypted wallet password",
	}
	survey.AskOne(prompt, &pword)
	return pword
}

func GetWalletEncryptionResp() bool {
	ans := false
	prompt := &survey.Confirm{
		Message: `Your wallet is currently UNENCRYPTED!

It is *highly* recommended that you encrypt your wallet before proceeding any further.

Encrypt it now?:`,
	}
	survey.AskOne(prompt, &ans)
	return ans
}

func getWalletResponse(sOut string) walletResponseType {
	if sOut == "" {
		return wrtNotReady
	}

	if strings.Contains(sOut, "hdseed") {
		return wrtAllOK
	}

	if strings.Contains(sOut, "wallet") {
		return wrtAllOK
	}

	return wrtUnknown
}

// IsCoinDaemonRunning - Works out whether the coin Daemon is running e.g. divid
func IsCoinDaemonRunning() (bool, int, error) {
	var pid int
	gwconf, err := gwc.GetCLIConfStruct()
	if err != nil {
		return false, pid, err
	}
	switch gwconf.ProjectType {
	case gwc.PTDivi:
		if runtime.GOOS == "windows" {
			pid, _, err = findProcess(gwc.CDiviDFileWin)
		} else {
			pid, _, err = findProcess(gwc.CDiviDFile)
		}
	case gwc.PTPIVX:
		if runtime.GOOS == "windows" {
			pid, _, err = findProcess(gwc.CPIVXDFileWin)
		} else {
			pid, _, err = findProcess(gwc.CPIVXDFile)
		}
	case gwc.PTTrezarcoin:
		if runtime.GOOS == "windows" {
			pid, _, err = findProcess(gwc.CTrezarcoinDFileWin)
		} else {
			pid, _, err = findProcess(gwc.CTrezarcoinDFile)
		}
	default:
		err = errors.New("unable to determine ProjectType")
	}

	if err == nil {
		return true, pid, nil //fmt.Printf ("Pid:%d, Pname:%s\n", pid, s)
	}
	return false, 0, err
}

// PopulateDaemonConfFile - Populates the divi.conf file
func PopulateDaemonConfFile() (rpcuser, rpcpassword string, err error) {
	abf, err := gwc.GetAppsBinFolder(gwc.APPTCLI)
	if err != nil {
		return "", "", fmt.Errorf("unable to GetAppsBinFolder - %v", err)
	}
	coind, err := gwc.GetCoinDaemonFilename(gwc.APPTCLI)
	if err != nil {
		return "", "", fmt.Errorf("unable to GetCoinDaemonFilename - %v", err)
	}

	gwconf, err := gwc.GetCLIConfStruct()
	if err != nil {
		return "", "", fmt.Errorf("unable to GetConfigStruct - %v", err)
	}
	switch gwconf.ProjectType {
	case gwc.PTDivi:

		fmt.Println("Populating " + gwc.CDiviConfFile + " for initial setup...")

		chd, _ := gwc.GetCoinHomeFolder(gwc.APPTCLI)
		if err := os.MkdirAll(chd, os.ModePerm); err != nil {
			return "", "", fmt.Errorf("unable to make directory - %v", err)
		}

		// Generate a random password
		rpcu := "divirpc"
		rpcpw := rand.String(20)

		if err := gwc.WriteTextToFile(chd+gwc.CDiviConfFile, cRPCUserStr+"="+rpcu); err != nil {
			log.Fatal(err)
		}
		if err := gwc.WriteTextToFile(chd+gwc.CDiviConfFile, cRPCPasswordStr+"="+rpcpw); err != nil {
			log.Fatal(err)
		}
		if err := gwc.WriteTextToFile(chd+gwc.CDiviConfFile, ""); err != nil {
			log.Fatal(err)
		}
		if err := gwc.WriteTextToFile(chd+gwc.CDiviConfFile, "daemon=1"); err != nil {
			log.Fatal(err)
		}
		if err := gwc.WriteTextToFile(chd+gwc.CDiviConfFile, ""); err != nil {
			log.Fatal(err)
		}
		if err := gwc.WriteTextToFile(chd+gwc.CDiviConfFile, "server=1"); err != nil {
			log.Fatal(err)
		}
		if err := gwc.WriteTextToFile(chd+gwc.CDiviConfFile, "rpcallowip=192.168.1.0/255.255.255.0"); err != nil {
			log.Fatal(err)
		}
		if err := gwc.WriteTextToFile(chd+gwc.CDiviConfFile, "rpcport=51473"); err != nil {
			log.Fatal(err)
		}

		// Now get a list of the latest "addnodes" and add them to the file:
		// gdc.AddToLog(lfp, "Adding latest master nodes to "+gdc.CDiviConfFile)
		//if err := AddAddNodesIfRequired(); err != nil {
		//	log.Println("Unable to add addnodes, but will try again on start...")
		//}

		return rpcu, rpcpw, nil
	case gwc.PTTrezarcoin:
		//Run divid for the first time, so that we can get the outputted info to build the conf file
		fmt.Println("Attempting to run " + coind + " for the first time...")
		cmdTrezarCDRun := exec.Command(abf + coind)
		if err := cmdTrezarCDRun.Start(); err != nil {
			return "", "", fmt.Errorf("failed to start %v: %v", coind, err)
		}

		return "", "", nil

	default:
		err = errors.New("unable to determine ProjectType")
	}
	return "", "", nil
}

// WalletHardFix - Deletes the local blockchain and forces it to sync again, a re-index should be performed first
func WalletHardFix() error {
	// Stop divid if it's running
	if err := StopCoinDaemon(false); err != nil {
		return fmt.Errorf("unable to StopDiviD: %v", err)
	}

	chf, err := gwc.GetCoinHomeFolder(gwc.APPTCLI)
	if err != nil {
		return fmt.Errorf("unable to get coin home folder: %v", err)
	}

	gwconf, err := gwc.GetCLIConfStruct()
	if err != nil {
		return err
	}
	switch gwconf.ProjectType {
	case gwc.PTDivi:
		if runtime.GOOS == "windows" {
			// TODO Complete for Windows
		} else {
			//rm -r ~/.divi/blocks
			if err := os.RemoveAll(chf + "blocks"); err != nil {
				return fmt.Errorf("unable to remove the blocks folder: %v", err)
			}
			//rm -r ~/.divi/chainstate
			if err := os.RemoveAll(chf + "chainstate"); err != nil {
				return fmt.Errorf("unable to remove the chainstate folder: %v", err)
			}
			//rm -r ~/.divi/database
			if err := os.RemoveAll(chf + "database"); err != nil {
				return fmt.Errorf("unable to remove the database folder: %v", err)
			}
			//rm -r ~/.divi/sporks
			if err := os.RemoveAll(chf + "sporks"); err != nil {
				return fmt.Errorf("unable to remove the sporks folder: %v", err)
			}
			//rm -r ~/.divi/zerocoin
			if err := os.RemoveAll(chf + "zerocoin"); err != nil {
				return fmt.Errorf("unable to remove the zerocoin folder: %v", err)
			}

			//rm -r ~/.divi/db.log
			if err := os.Remove(chf + "db.log"); err != nil {
				return fmt.Errorf("unable to remove the db.log file: %v", err)
			}
			//rm -r ~/.divi/debug.log
			if err := os.Remove(chf + "debug.log"); err != nil {
				return fmt.Errorf("unable to remove the debug.log file: %v", err)
			}
			//rm -r ~/.divi/fee_estimates.dat
			if err := os.Remove(chf + "fee_estimates.dat"); err != nil {
				return fmt.Errorf("unable to remove the fee_estimates.dat file: %v", err)
			}
			//rm -r ~/.divi/peers.dat
			if err := os.Remove(chf + "peers.dat"); err != nil {
				return fmt.Errorf("unable to remove the peers.dat file: %v", err)
			}
			//rm -r ~/.divi/mncache.dat
			if err := os.Remove(chf + "mncache.dat"); err != nil {
				return fmt.Errorf("unable to remove the mncache.dat file: %v", err)
			}
			//rm -r ~/.divi/mnpayments.dat
			if err := os.Remove(chf + "mnpayments.dat"); err != nil {
				return fmt.Errorf("unable to remove the mnpayments.dat file: %v", err)
			}
			//rm -r ~/.divi/netfulfilled.dat
			if err := os.Remove(chf + "netfulfilled.dat"); err != nil {
				return fmt.Errorf("unable to remove the netfulfilled.dat file: %v", err)
			}

			// Now start the divid daemon again...
			os.Exit(0)
			//if err := RunCoinDaemon(false); err != nil {
			//	log.Fatalf("failed to run divid: %v", err)
			//}
		}
	case gwc.PTPIVX:
	case gwc.PTTrezarcoin:
	default:
		err = errors.New("unable to determine ProjectType")
	}

	return nil
}

func WalletFix(wft WalletFixType) error {
	// Stop divid if it's running
	if err := StopCoinDaemon(false); err != nil {
		return fmt.Errorf("unable to StopDiviD: %v", err)
	}

	dbf, _ := gwc.GetAppsBinFolder(gwc.APPTCLI)
	coind, err := gwc.GetCoinDaemonFilename(gwc.APPTCLI)
	if err != nil {
		return fmt.Errorf("unable to GetCoinDaemonFilename - %v", err)
	}

	gwconf, err := gwc.GetCLIConfStruct()
	if err != nil {
		return err
	}
	switch gwconf.ProjectType {
	case gwc.PTDivi:
		if runtime.GOOS == "windows" {
			// TODO Complete for Windows
		} else {
			var arg1 string
			switch wft {
			case WFTReIndex:
				arg1 = "-reindex"
			case WFTReSync:
				arg1 = "-resync"
			}

			cRun := exec.Command(dbf+coind, arg1)
			if err := cRun.Run(); err != nil {
				return fmt.Errorf("unable to run divid -reindex: %v", err)
			}
		}
	case gwc.PTPIVX:
		if runtime.GOOS == "windows" {
			// TODO Complete for Windows
		} else {
			cRun := exec.Command(dbf+coind, "-reindex")
			if err := cRun.Run(); err != nil {
				return fmt.Errorf("unable to run pivxd -reindex: %v", err)
			}
		}
	case gwc.PTTrezarcoin:
		if runtime.GOOS == "windows" {
			// TODO Complete for Windows
		} else {
			cRun := exec.Command(dbf+coind, "-reindex")
			if err := cRun.Run(); err != nil {
				return fmt.Errorf("unable to run trezardcoind -reindex: %v", err)
			}
		}
	default:
		err = errors.New("unable to determine ProjectType")
	}

	return nil
}

func runDCCommand(cmdBaseStr, cmdStr, waitingStr string, attempts int) (string, error) {
	var err error
	//var s string = waitingStr
	for i := 0; i < attempts; i++ {
		cmd := exec.Command(cmdBaseStr, cmdStr)
		out, err := cmd.CombinedOutput()

		if err == nil {
			return string(out), err
		}
		fmt.Printf("\r"+waitingStr+" %d/"+strconv.Itoa(attempts), i)

		time.Sleep(3 * time.Second)
	}

	return "", err
}

func runDCCommandWithValue(cmdBaseStr, cmdStr, valueStr, waitingStr string, attempts int) (string, error) {
	var err error
	//var s string = waitingStr
	for i := 0; i < attempts; i++ {
		cmd := exec.Command(cmdBaseStr, cmdStr, valueStr)
		out, err := cmd.CombinedOutput()

		if err == nil {
			return string(out), err
		}
		fmt.Printf("\r"+waitingStr+" %d/"+strconv.Itoa(attempts), i)
		time.Sleep(3 * time.Second)
	}

	return "", err
}

// RunCoinDaemon - Run the coins Daemon e.g. Run divid
func RunCoinDaemon(displayOutput bool) error {
	idr, _, _ := IsCoinDaemonRunning()
	if idr == true {
		// Already running...
		return nil
	}

	gwconf, err := gwc.GetCLIConfStruct()
	if err != nil {
		return err
	}
	abf, _ := gwc.GetAppsBinFolder(gwc.APPTCLI)

	switch gwconf.ProjectType {
	case gwc.PTDivi:
		if runtime.GOOS == "windows" {
			//_ = exec.Command(GetAppsBinFolder() + cDiviDFileWin)
			fp := abf + gwc.CDiviDFileWin
			cmd := exec.Command("cmd.exe", "/C", "start", "/b", fp)
			if err := cmd.Run(); err != nil {
				return err
			}
		} else {
			if displayOutput {
				fmt.Println("Attempting to run the divid daemon...")
			}

			cmdRun := exec.Command(abf + gwc.CDiviDFile)
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
				if string(line) == "DIVI server starting" {
					if displayOutput {
						fmt.Println("DIVI server starting")
					}
					return nil
				} else {
					return errors.New("unable to start Divi server: " + string(line))
				}
			}
		}
	case gwc.PTTrezarcoin:
		// TODO Need to code this bit for Trezarcoin
	default:
		err = errors.New("unable to determine ProjectType")
	}
	return nil
}

// stopCoinDaemon - Stops the coin daemon (e.g. divid) from running
func StopCoinDaemon(displayOutput bool) error {
	idr, _, _ := gwc.IsCoinDaemonRunning() //DiviDRunning()
	if idr != true {
		// Not running anyway ...
		return nil
	}

	dbf, _ := gwc.GetAppsBinFolder(gwc.APPTCLI)
	coind, err := gwc.GetCoinDaemonFilename(gwc.APPTCLI)
	if err != nil {
		return fmt.Errorf("unable to GetCoinDaemonFilename - %v", err)
	}

	gwconf, err := gwc.GetCLIConfStruct()
	if err != nil {
		return err
	}
	switch gwconf.ProjectType {
	case gwc.PTDivi:
		if runtime.GOOS == "windows" {
			// TODO Complete for Windows
		} else {
			for i := 0; i < 50; i++ {
				cRun := exec.Command(dbf+gwc.CDiviCliFile, "stop")
				_ = cRun.Run()

				sr, _, _ := IsCoinDaemonRunning() //DiviDRunning()
				if !sr {
					// Lets wait a little longer before returning
					time.Sleep(3 * time.Second)
					return nil
				}
				if displayOutput {
					fmt.Printf("\rWaiting for divid server to stop %d/"+strconv.Itoa(50), i+1)
				}
				time.Sleep(3 * time.Second)
			}
		}
	case gwc.PTPIVX:
		if runtime.GOOS == "windows" {
			// TODO Complete for Windows
		} else {
			cRun := exec.Command(dbf+gwc.CPIVXCliFile, "stop")
			if err := cRun.Run(); err != nil {
				return fmt.Errorf("unable to StopPIVXD:%v", err)
			}

			for i := 0; i < 50; i++ {
				sr, _, _ := IsCoinDaemonRunning()
				if !sr {
					return nil
				}
				if displayOutput {
					fmt.Printf("\rWaiting for pivxd server to stop %d/"+strconv.Itoa(50), i+1)
				}
				time.Sleep(3 * time.Second)

			}
		}
	case gwc.PTTrezarcoin:
		if runtime.GOOS == "windows" {
			// TODO Complete for Windows
		} else {
			cRun := exec.Command(dbf+gwc.CTrezarcoinCliFile, "stop")
			if err := cRun.Run(); err != nil {
				return fmt.Errorf("unable to StopCoinDaemon:%v", err)
			}

			for i := 0; i < 50; i++ {
				sr, _, _ := IsCoinDaemonRunning() //DiviDRunning()
				if !sr {
					return nil
				}
				if displayOutput {
					fmt.Printf("\rWaiting for "+coind+" server to stop %d/"+strconv.Itoa(50), i+1)
				}
				time.Sleep(3 * time.Second)

			}
		}
	default:
		err = errors.New("unable to determine ProjectType")
	}

	return nil
}

// RunInitialDaemon - Runs the divid Daemon for the first time to populate the divi.conf file
func RunInitialDaemon() (rpcuser, rpcpassword string, err error) {
	abf, err := gwc.GetAppsBinFolder(gwc.APPTCLI)
	if err != nil {
		return "", "", fmt.Errorf("unable to GetAppsBinFolder - %v", err)
	}
	coind, err := gwc.GetCoinDaemonFilename(gwc.APPTCLI)
	if err != nil {
		return "", "", fmt.Errorf("unable to GetCoinDaemonFilename - %v", err)
	}

	gwconf, err := gwc.GetCLIConfStruct()
	if err != nil {
		return "", "", fmt.Errorf("unable to GetConfigStruct - %v", err)
	}
	switch gwconf.ProjectType {
	case gwc.PTDivi:
		//Run divid for the first time, so that we can get the outputted info to build the conf file
		fmt.Println("About to run " + coind + " for the first time...")
		cmdDividRun := exec.Command(abf + gwc.CDiviDFile)
		out, _ := cmdDividRun.CombinedOutput()
		fmt.Println("Populating " + gwc.CDiviConfFile + " for initial setup...")

		scanner := bufio.NewScanner(strings.NewReader(string(out)))
		var rpcuser, rpcpw string
		for scanner.Scan() {
			s := scanner.Text()
			if strings.Contains(s, cRPCUserStr) {
				rpcuser = strings.ReplaceAll(s, cRPCUserStr+"=", "")
			}
			if strings.Contains(s, cRPCPasswordStr) {
				rpcpw = strings.ReplaceAll(s, cRPCPasswordStr+"=", "")
			}
		}

		chd, _ := gwc.GetCoinHomeFolder(gwc.APPTCLI)

		if err := gwc.WriteTextToFile(chd+gwc.CDiviConfFile, cRPCUserStr+"="+rpcuser); err != nil {
			log.Fatal(err)
		}
		if err := gwc.WriteTextToFile(chd+gwc.CDiviConfFile, cRPCPasswordStr+"="+rpcpw); err != nil {
			log.Fatal(err)
		}
		if err := gwc.WriteTextToFile(chd+gwc.CDiviConfFile, ""); err != nil {
			log.Fatal(err)
		}
		if err := gwc.WriteTextToFile(chd+gwc.CDiviConfFile, "daemon=1"); err != nil {
			log.Fatal(err)
		}
		if err := gwc.WriteTextToFile(chd+gwc.CDiviConfFile, ""); err != nil {
			log.Fatal(err)
		}
		if err := gwc.WriteTextToFile(chd+gwc.CDiviConfFile, "server=1"); err != nil {
			log.Fatal(err)
		}
		if err := gwc.WriteTextToFile(chd+gwc.CDiviConfFile, "rpcallowip=0.0.0.0/0"); err != nil {
			log.Fatal(err)
		}
		if err := gwc.WriteTextToFile(chd+gwc.CDiviConfFile, "rpcport=8332"); err != nil {
			log.Fatal(err)
		}

		// Now get a list of the latest "addnodes" and add them to the file:
		// I've commented out the below, as I think it might cause future issues with blockchain syncing,
		// because, I think that the ipaddresses in the conf file are used before any others are picked up,
		// so, it's possible that they could all go, and then cause issues.

		// gdc.AddToLog(lfp, "Adding latest master nodes to "+gdc.CDiviConfFile)
		// addnodes, _ := gdc.GetAddNodes()
		// sAddnodes := string(addnodes[:])
		// gdc.WriteTextToFile(dhd+gdc.CDiviConfFile, sAddnodes)

		return rpcuser, rpcpw, nil
	case gwc.PTTrezarcoin:
		//Run divid for the first time, so that we can get the outputted info to build the conf file
		fmt.Println("Attempting to run " + coind + " for the first time...")
		cmdTrezarCDRun := exec.Command(abf + coind)
		if err := cmdTrezarCDRun.Start(); err != nil {
			return "", "", fmt.Errorf("failed to start %v: %v", coind, err)
		}

		return "", "", nil

	default:
		err = errors.New("unable to determine ProjectType")
	}
	return "", "", nil
}

// StopDaemon - Send a "stop" to the daemon, and returns the result
func StopDaemon(cliConf *gwc.CLIConfStruct) (GenericRespStruct, error) {
	var respStruct GenericRespStruct

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"stop\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+cliConf.ServerIP+":"+cliConf.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(cliConf.RPCuser, cliConf.RPCpassword)
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

// UnlockWallet - Used by the server to unlock the wallet
//func UnlockWallet(pword string, attempts int, forStaking bool) (bool, error) {
//	var err error
//	var s string = "waiting for wallet."
//	dbf, _ := gwc.GetAppsBinFolder(gwc.APPTServer)
//	app := dbf + gwc.CDiviCliFile
//	arg1 := cCommandUnlockWalletFS
//	arg2 := pword
//	arg3 := "0"
//	arg4 := "true"
//	for i := 0; i < attempts; i++ {
//
//		var cmd *exec.Cmd
//		if forStaking {
//			cmd = exec.Command(app, arg1, arg2, arg3, arg4)
//		} else {
//			cmd = exec.Command(app, arg1, arg2, arg3)
//		}
//		//fmt.Println("cmd = " + dbf + cDiviCliFile + cCommandUnlockWalletFS + `"` + pword + `"` + "0")
//		out, err := cmd.CombinedOutput()
//
//		fmt.Println("string = " + string(out))
//		//fmt.Println("error = " + err.Error())
//
//		if err == nil {
//			return true, err
//		}
//
//		if strings.Contains(string(out), "The wallet passphrase entered was incorrect.") {
//			return false, err
//		}
//
//		if strings.Contains(string(out), "Loading block index....") {
//			//s = s + "."
//			//fmt.Println(s)
//			fmt.Printf("\r"+s+" %d/"+strconv.Itoa(attempts), i+1)
//
//			time.Sleep(3 * time.Second)
//
//		}
//
//	}
//
//	return false, err
//}
