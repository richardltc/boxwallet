package bend

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"time"

	gwc "github.com/richardltc/gwcommon"
)

const (
	// Divi-cli command constants
	cCommandGetBCInfo     string = "getblockchaininfo"
	cCommandGetWInfo      string = "getwalletinfo"
	cCommandMNSyncStatus1 string = "mnsync"
	cCommandMNSyncStatus2 string = "status"

	// Divii-cli wallet commands
	cCommandDisplayWalletAddress string = "getaddressesbyaccount" // ./divi-cli getaddressesbyaccount ""
	cCommandDumpHDinfo           string = "dumphdinfo"            // ./divi-cli dumphdinfo
	// CCommandEncryptWallet - Needed by dash command
	CCommandEncryptWallet  string = "encryptwallet"    // ./divi-cli encryptwallet “a_strong_password”
	cCommandRestoreWallet  string = "-hdseed="         // ./divid -debug-hdseed=the_seed -rescan (stop divid, rename wallet.dat, then run command)
	cCommandUnlockWallet   string = "walletpassphrase" // ./divi-cli walletpassphrase “password” 0
	cCommandUnlockWalletFS string = "walletpassphrase" // ./divi-cli walletpassphrase “password” 0 true
	cCommandLockWallet     string = "walletlock"       // ./divi-cli walletlock

	cRPCUserStr     string = "rpcuser"
	cRPCPasswordStr string = "rpcpassword"
)

type blockChainInfo struct {
	Chain                string  `json:"chain"`
	Blocks               int     `json:"blocks"`
	Headers              int     `json:"headers"`
	Bestblockhash        string  `json:"bestblockhash"`
	Difficulty           float64 `json:"difficulty"`
	Verificationprogress float64 `json:"verificationprogress"`
	Chainwork            string  `json:"chainwork"`
}

type mnSyncStatus struct {
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
}

type privateSeedStruct struct {
	Hdseed             string `json:"hdseed"`
	Mnemonic           string `json:"mnemonic"`
	Mnemonicpassphrase string `json:"mnemonicpassphrase"`
}

type walletInfoStruct struct {
	Walletversion      int     `json:"walletversion"`
	Balance            float64 `json:"balance"`
	UnconfirmedBalance float64 `json:"unconfirmed_balance"`
	ImmatureBalance    float64 `json:"immature_balance"`
	Txcount            int     `json:"txcount"`
	Keypoololdest      int     `json:"keypoololdest"`
	Keypoolsize        int     `json:"keypoolsize"`
	UnlockedUntil      int     `json:"unlocked_until"`
	EncryptionStatus   string  `json:"encryption_status"`
	Hdchainid          string  `json:"hdchainid"`
	Hdaccountcount     int     `json:"hdaccountcount"`
	Hdaccounts         []struct {
		Hdaccountindex     int `json:"hdaccountindex"`
		Hdexternalkeyindex int `json:"hdexternalkeyindex"`
		Hdinternalkeyindex int `json:"hdinternalkeyindex"`
	} `json:"hdaccounts"`
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

type tickerStruct struct {
	DIVI struct {
		ID                int         `json:"id"`
		Name              string      `json:"name"`
		Symbol            string      `json:"symbol"`
		Slug              string      `json:"slug"`
		NumMarketPairs    int         `json:"num_market_pairs"`
		DateAdded         time.Time   `json:"date_added"`
		Tags              []string    `json:"tags"`
		MaxSupply         interface{} `json:"max_supply"`
		CirculatingSupply float64     `json:"circulating_supply"`
		TotalSupply       float64     `json:"total_supply"`
		Platform          interface{} `json:"platform"`
		CmcRank           int         `json:"cmc_rank"`
		LastUpdated       time.Time   `json:"last_updated"`
		Quote             struct {
			BTC struct {
				Price            float64   `json:"price"`
				Volume24H        float64   `json:"volume_24h"`
				PercentChange1H  float64   `json:"percent_change_1h"`
				PercentChange24H float64   `json:"percent_change_24h"`
				PercentChange7D  float64   `json:"percent_change_7d"`
				MarketCap        float64   `json:"market_cap"`
				LastUpdated      time.Time `json:"last_updated"`
			} `json:"BTC"`
			USD struct {
				Price            float64   `json:"price"`
				Volume24H        float64   `json:"volume_24h"`
				PercentChange1H  float64   `json:"percent_change_1h"`
				PercentChange24H float64   `json:"percent_change_24h"`
				PercentChange7D  float64   `json:"percent_change_7d"`
				MarketCap        float64   `json:"market_cap"`
				LastUpdated      time.Time `json:"last_updated"`
			} `json:"USD"`
		} `json:"quote"`
	} `json:"DIVI"`
}

type walletResponseType int

const (
	wrType walletResponseType = iota
	wrtUnknown
	wrtAllOK
	wrtNotReady
	wrtStillLoading
)

func GetPrivKey() (privateSeedStruct, walletResponseType, error) {
	ps := privateSeedStruct{}

	// Start the DiviD server if required...
	err := RunCoinDaemon(false)
	if err != nil {
		return ps, wrtUnknown, fmt.Errorf("Unable to RunDiviD: %v ", err)
	}

	dbf, err := gwc.GetAppsBinFolder(gwc.APPTServer)
	if err != nil {
		return ps, wrtUnknown, fmt.Errorf("Unable to GetAppsBinFolder: %v ", err)
	}

	for i := 0; i <= 4; i++ {
		cmd := exec.Command(dbf+gwc.CDiviCliFile, cCommandDumpHDinfo)
		var stdout bytes.Buffer
		cmd.Stdout = &stdout
		cmd.Run()
		if err != nil {
			return ps, wrtUnknown, err
		}

		outStr := string(stdout.Bytes())
		wr := getWalletResponse(outStr)

		if wr == wrtAllOK {
			errUM := json.Unmarshal([]byte(outStr), &ps)
			if errUM == nil {
				return ps, wrtAllOK, err
			}
		}

		time.Sleep(1 * time.Second)
	}

	// return ps, wrtUnknown, errors.New("Unable to retrieve wallet info")

	// dbf, err := gwc.GetAppsBinFolder(gwc.APPTServer)
	// if err != nil {
	// 	return "", fmt.Errorf("Unable to GetAppsBinFolder: %v", err)
	// }
	// s, err := runDCCommand(dbf+gwc.CDiviCliFile, cCommandDumpHDinfo, "Waiting for wallet to respond. This could take several minutes...", 30)
	// if err != nil {
	// 	return "", fmt.Errorf("Unable to run command: %v - %v", dbf+gwc.CDiviCliFile+cCommandDumpHDinfo, err)
	// }

	return ps, wrtUnknown, errors.New("Unable to retrieve priv key")
}

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

func getBlockchainInfo() (blockChainInfo, error) {
	bci := blockChainInfo{}
	dbf, _ := gwc.GetAppsBinFolder(gwc.APPTServer)

	cmdBCInfo := exec.Command(dbf+gwc.CDiviCliFile, cCommandGetBCInfo)
	out, _ := cmdBCInfo.CombinedOutput()
	err := json.Unmarshal([]byte(out), &bci)
	if err != nil {
		return bci, err
	}
	return bci, nil
}

func getMNSyncStatus() (mnSyncStatus, error) {
	// gdConfig, err := getConfStruct("./")
	// if err != nil {
	// 	log.Print(err)
	// }

	mnss := mnSyncStatus{}
	dbf, _ := gwc.GetAppsBinFolder(gwc.APPTServer)

	cmdMNSS := exec.Command(dbf+gwc.CDiviCliFile, cCommandMNSyncStatus1, cCommandMNSyncStatus2)
	out, _ := cmdMNSS.CombinedOutput()
	err := json.Unmarshal([]byte(out), &mnss)
	if err != nil {
		return mnss, err
	}
	return mnss, nil
}

func getWalletAddress(attempts int) (string, error) {
	var err error
	var s string = "waiting for wallet."
	dbf, _ := gwc.GetAppsBinFolder(gwc.APPTServer)
	app := dbf + gwc.CDiviCliFile
	arg1 := cCommandDisplayWalletAddress
	arg2 := ""

	for i := 0; i < attempts; i++ {

		cmd := exec.Command(app, arg1, arg2)
		out, err := cmd.CombinedOutput()

		if err == nil {
			return string(out), err
		}

		fmt.Printf("\r"+s+" %d/"+strconv.Itoa(attempts), i+1)

		time.Sleep(3 * time.Second)
	}

	return "", err

}

func GetWalletInfo(dispProgress bool) (walletInfoStruct, walletResponseType, error) {
	wi := walletInfoStruct{}

	// Start the DiviD server if required...
	err := RunCoinDaemon(false)
	if err != nil {
		return wi, wrtUnknown, fmt.Errorf("Unable to RunDiviD: %v ", err)
	}

	dbf, err := gwc.GetAppsBinFolder(gwc.APPTServer)
	if err != nil {
		return wi, wrtUnknown, fmt.Errorf("Unable to GetAppsBinFolder: %v ", err)
	}

	for i := 0; i <= 4; i++ {
		cmd := exec.Command(dbf+gwc.CDiviCliFile, cCommandGetWInfo)
		var stdout bytes.Buffer
		cmd.Stdout = &stdout
		cmd.Run()
		if err != nil {
			return wi, wrtUnknown, err
		}

		outStr := string(stdout.Bytes())
		wr := getWalletResponse(outStr)

		// cmd := exec.Command(dbf+gwc.CDiviCliFile, cCommandGetWInfo)
		// out, err := cmd.CombinedOutput()
		// sOut := string(out)
		//wr := getWalletResponse(sOut)
		if wr == wrtAllOK {
			errUM := json.Unmarshal([]byte(outStr), &wi)
			if errUM == nil {
				return wi, wrtAllOK, err
			}
		}

		time.Sleep(1 * time.Second)
	}

	return wi, wrtUnknown, errors.New("Unable to retrieve wallet info")
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

func runDCCommand(cmdBaseStr, cmdStr, waitingStr string, attempts int) (string, error) {
	var err error
	//var s string = waitingStr
	for i := 0; i < attempts; i++ {
		cmd := exec.Command(cmdBaseStr, cmdStr)
		out, err := cmd.CombinedOutput()

		// cmd := exec.Command(cmdBaseStr, cmdStr)
		// cmd.Stdout = os.Stdout
		// cmd.Stderr = os.Stderr
		// err = cmd.Run()

		if err == nil {
			return string(out), err
		}
		//s = s + "."
		//fmt.Println(s)
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
		//s = s + "."
		//fmt.Println(s)
		fmt.Printf("\r"+waitingStr+" %d/"+strconv.Itoa(attempts), i)
		time.Sleep(3 * time.Second)
	}

	return "", err
}

// RunCoinDaemon - Run the coins Daemon e.g. Run divid
func RunCoinDaemon(displayOutput bool) error {
	idr, _, _ := gwc.IsCoinDaemonRunning()
	if idr == true {
		// Already running...
		return nil
	}

	gwconf, err := gwc.GetServerConfStruct()
	if err != nil {
		return err
	}
	abf, _ := gwc.GetAppsBinFolder(gwc.APPTServer)

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
			cmdRun.Start()

			buf := bufio.NewReader(stdout) // Notice that this is not in a loop
			num := 1
			for {
				line, _, _ := buf.ReadLine()
				if num > 3 {
					os.Exit(0)
				}
				num++
				if string(line) == "DIVI server starting" {
					return nil
				} else {
					return errors.New("Unable to start Divi server")
				}
			}
		}
	case gwc.PTTrezarcoin:

	default:
		err = errors.New("Unable to determine ProjectType")
	}
	return nil
}

// stopCoinDaemon - Stops the coin daemon (e.g. divid) from running
func stopCoinDaemon() error {
	idr, _, _ := gwc.IsCoinDaemonRunning() //DiviDRunning()
	if idr != true {
		// Not running anyway ...
		return nil
	}

	dbf, _ := gwc.GetAppsBinFolder(gwc.APPTServer)
	coind, err := gwc.GetCoinDaemonFilename(gwc.APPTServer)
	if err != nil {
		return fmt.Errorf("Unable to GetCoinDaemonFilename - %v", err)
	}

	gwconf, err := gwc.GetCLIConfStruct()
	if err != nil {
		return err
	}
	switch gwconf.ProjectType {
	case gwc.PTDivi:
		if runtime.GOOS == "windows" {

		} else {
			cRun := exec.Command(dbf+gwc.CDiviCliFile, "stop")
			if err := cRun.Run(); err != nil {
				return fmt.Errorf("Unable to StopDiviD:%v", err)
			}

			for i := 0; i < 50; i++ {
				sr, _, _ := gwc.IsCoinDaemonRunning() //DiviDRunning()
				if !sr {
					return nil
				}
				fmt.Printf("\rWaiting for divid server to stop %d/"+strconv.Itoa(50), i+1)
				time.Sleep(3 * time.Second)

			}
		}
	case gwc.PTPIVX:
		if runtime.GOOS == "windows" {

		} else {
			cRun := exec.Command(dbf+gwc.CPIVXCliFile, "stop")
			if err := cRun.Run(); err != nil {
				return fmt.Errorf("Unable to StopPIVXD:%v", err)
			}

			for i := 0; i < 50; i++ {
				sr, _, _ := gwc.IsCoinDaemonRunning() //DiviDRunning()
				if !sr {
					return nil
				}
				fmt.Printf("\rWaiting for pivxd server to stop %d/"+strconv.Itoa(50), i+1)
				time.Sleep(3 * time.Second)

			}
		}
	case gwc.PTTrezarcoin:
		if runtime.GOOS == "windows" {

		} else {
			cRun := exec.Command(dbf+gwc.CTrezarcoinCliFile, "stop")
			if err := cRun.Run(); err != nil {
				return fmt.Errorf("Unable to StopCoinDaemon:%v", err)
			}

			for i := 0; i < 50; i++ {
				sr, _, _ := gwc.IsCoinDaemonRunning() //DiviDRunning()
				if !sr {
					return nil
				}
				fmt.Printf("\rWaiting for "+coind+" server to stop %d/"+strconv.Itoa(50), i+1)
				time.Sleep(3 * time.Second)

			}
		}
	default:
		err = errors.New("Unable to determine ProjectType")
	}

	return nil
}

// RunInitialDaemon - Runs the divid Daemon for the first time to populate the divi.conf file
func RunInitialDaemon() error {
	abf, err := gwc.GetAppsBinFolder(gwc.APPTServer)
	if err != nil {
		return fmt.Errorf("Unable to GetAppsBinFolder - %v", err)
	}
	coind, err := gwc.GetCoinDaemonFilename(gwc.APPTServer)
	if err != nil {
		return fmt.Errorf("Unable to GetCoinDaemonFilename - %v", err)
	}

	gwconf, err := gwc.GetServerConfStruct()
	if err != nil {
		return fmt.Errorf("Unable to GetConfigStruct - %v", err)
	}
	switch gwconf.ProjectType {
	case gwc.PTDivi:
		//Run divid for the first time, so that we can get the outputted info to build the conf file
		fmt.Println("About to run " + coind + " for the first time...")
		cmdDividRun := exec.Command(abf + gwc.CDiviDFile)
		out, _ := cmdDividRun.CombinedOutput()
		// out, err := cmdDividRun.CombinedOutput()
		// if err != nil {
		// 	return fmt.Errorf("Unable to run "+abf+cDiviDFile+" - %v", err)
		// }
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

		chd, _ := gwc.GetCoinHomeFolder(gwc.APPTServer)

		err = gwc.WriteTextToFile(chd+gwc.CDiviConfFile, cRPCUserStr+"="+rpcuser)
		if err != nil {
			log.Fatal(err)
		}
		err = gwc.WriteTextToFile(chd+gwc.CDiviConfFile, cRPCPasswordStr+"="+rpcpw)
		if err != nil {
			log.Fatal(err)
		}
		err = gwc.WriteTextToFile(chd+gwc.CDiviConfFile, "")
		if err != nil {
			log.Fatal(err)
		}
		err = gwc.WriteTextToFile(chd+gwc.CDiviConfFile, "daemon=1")
		if err != nil {
			log.Fatal(err)
		}
		err = gwc.WriteTextToFile(chd+gwc.CDiviConfFile, "")
		if err != nil {
			log.Fatal(err)
		}

		// Now get a list of the latest "addnodes" and add them to the file:
		// I've commented out the below, as I think it might cause future issues with blockchain syncing,
		// because, I think that the ipaddresess in the conf file are used before any others are picked up,
		// so, it's possible that they could all go, and then cause issues.

		// gdc.AddToLog(lfp, "Adding latest master nodes to "+gdc.CDiviConfFile)
		// addnodes, _ := gdc.GetAddNodes()
		// sAddnodes := string(addnodes[:])
		// gdc.WriteTextToFile(dhd+gdc.CDiviConfFile, sAddnodes)

		return nil
	case gwc.PTTrezarcoin:
		//Run divid for the first time, so that we can get the outputted info to build the conf file
		fmt.Println("Attempting to run " + coind + " for the first time...")
		cmdTrezarCDRun := exec.Command(abf + coind)
		if err := cmdTrezarCDRun.Start(); err != nil {
			return fmt.Errorf("Failed to start %v: %v", coind, err)
		}

		return nil

	default:
		err = errors.New("Unable to determine ProjectType")
	}
	return nil
}

// UnlockWallet - Used by the server to unlock the wallet
func UnlockWallet(pword string, attempts int, forStaking bool) (bool, error) {
	var err error
	var s string = "waiting for wallet."
	dbf, _ := gwc.GetAppsBinFolder(gwc.APPTServer)
	app := dbf + gwc.CDiviCliFile
	arg1 := cCommandUnlockWalletFS
	arg2 := pword
	arg3 := "0"
	arg4 := "true"
	for i := 0; i < attempts; i++ {

		var cmd *exec.Cmd
		if forStaking {
			cmd = exec.Command(app, arg1, arg2, arg3, arg4)
		} else {
			cmd = exec.Command(app, arg1, arg2, arg3)
		}
		//fmt.Println("cmd = " + dbf + cDiviCliFile + cCommandUnlockWalletFS + `"` + pword + `"` + "0")
		out, err := cmd.CombinedOutput()

		fmt.Println("string = " + string(out))
		//fmt.Println("error = " + err.Error())

		if err == nil {
			return true, err
		}

		if strings.Contains(string(out), "The wallet passphrase entered was incorrect.") {
			return false, err
		}

		if strings.Contains(string(out), "Loading block index....") {
			//s = s + "."
			//fmt.Println(s)
			fmt.Printf("\r"+s+" %d/"+strconv.Itoa(attempts), i+1)

			time.Sleep(3 * time.Second)

		}

	}

	return false, err
}
