package bend

import (
	"bytes"
	"encoding/json"
	"github.com/dustin/go-humanize"
	"github.com/theckman/yacspin"
	"io/ioutil"
	"net/http"
	"strings"
	"time"
)

const (
	CCoinNameDenarius   string = "Denarius"
	CCoinAbbrevDenarius string = "D"

	CCoreVersionDenarius string = "3.3.9.11"
	//CDFRPiDenarius       string = "Denarius-" + CDenariusCoreVersion + "-arm-linux-gnueabihf.tar.gz"
	//CDFLinuxDenarius     string = "Denarius-" + CDenariusCoreVersion + "-x86_64-linux-gnu.tar.gz"
	CDFDenariusWindows string = "Denarius-" + CCoreVersionDenarius + "-Win64.zip"
	CDFDenariusBS      string = "chaindata.zip"
	CDFDenariusBSARM   string = "pichaindata.zip"

	//CDenariusExtractedDirLinux   = "Denarius-" + CDenariusCoreVersion + "/"
	CDenariusExtractedDirWindows = "Denarius-" + CCoreVersionDenarius + "\\"

	CDownloadURLDenarius   string = "https://github.com/carsenk/denarius/releases/download/v" + CCoreVersionDenarius + "/"
	CDownloadURLDenariusBS string = "https://denarii.cloud/"

	CDenariusBinDirLinux string = "/snap/bin/"
	cHomeDirLinDenarius  string = "snap/denarius/common/.denarius"
	cHomeDirWinDenarius  string = "denarius"

	// Files
	CDenariusConfFile   string = "denarius.conf"
	CDenariusCliFile    string = "denarius"
	CDenariusCliFileWin string = "denarius-cli.exe"
	CDFileDenarius      string = "denarius.daemon"
	CDenariusDMem       string = "denariusd"
	CDenariusDFileWin   string = "denarius.daemon.exe"
	CDenariusTxFile     string = "denarius-tx"
	CDenariusTxFileWin  string = "denarius-tx.exe"

	// Networking
	cDenariusRPCUser string = "denariusrpc"
	CDenariusRPCPort string = "32369"
)

type DenariusBlockchainInfoRespStruct struct {
	Result struct {
		Chain         string `json:"chain"`
		Blocks        int    `json:"blocks"`
		Bestblockhash string `json:"bestblockhash"`
		Difficulty    struct {
			ProofOfWork  float64 `json:"proof-of-work"`
			ProofOfStake float64 `json:"proof-of-stake"`
		} `json:"difficulty"`
		Initialblockdownload bool    `json:"initialblockdownload"`
		Moneysupply          float64 `json:"moneysupply"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type DenariusGetInfoRespStruct struct {
	Result struct {
		Version         string  `json:"version"`
		Protocolversion int     `json:"protocolversion"`
		Walletversion   int     `json:"walletversion"`
		Balance         float64 `json:"balance"`
		Anonbalance     float64 `json:"anonbalance"`
		Reserve         float64 `json:"reserve"`
		Newmint         float64 `json:"newmint"`
		Stake           float64 `json:"stake"`
		Unconfirmed     float64 `json:"unconfirmed"`
		Immature        float64 `json:"immature"`
		Blocks          int     `json:"blocks"`
		Timeoffset      int     `json:"timeoffset"`
		Moneysupply     float64 `json:"moneysupply"`
		Connections     int     `json:"connections"`
		Datareceived    string  `json:"datareceived"`
		Datasent        string  `json:"datasent"`
		Proxy           string  `json:"proxy"`
		IP              string  `json:"ip"`
		Difficulty      struct {
			ProofOfWork  float64 `json:"proof-of-work"`
			ProofOfStake float64 `json:"proof-of-stake"`
		} `json:"difficulty"`
		Netmhashps           float64 `json:"netmhashps"`
		Netstakeweight       float64 `json:"netstakeweight"`
		Weight               int     `json:"weight"`
		Testnet              bool    `json:"testnet"`
		Fortunastake         bool    `json:"fortunastake"`
		Fslock               bool    `json:"fslock"`
		Nativetor            bool    `json:"nativetor"`
		Keypoololdest        int     `json:"keypoololdest"`
		Keypoolsize          int     `json:"keypoolsize"`
		Paytxfee             float64 `json:"paytxfee"`
		Mininput             float64 `json:"mininput"`
		Datadir              string  `json:"datadir"`
		Initialblockdownload bool    `json:"initialblockdownload"`
		UnlockedUntil        int     `json:"unlocked_until"`
		WalletStatus         string  `json:"wallet_status"`
		Errors               string  `json:"errors"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type DenariusGetStakingInfoRespStruct struct {
	Result struct {
		Enabled          bool    `json:"enabled"`
		Staking          bool    `json:"staking"`
		Errors           string  `json:"errors"`
		Currentblocksize int     `json:"currentblocksize"`
		Currentblocktx   int     `json:"currentblocktx"`
		Pooledtx         int     `json:"pooledtx"`
		Difficulty       float64 `json:"difficulty"`
		SearchInterval   int     `json:"search-interval"`
		Weight           int     `json:"weight"`
		Netstakeweight   int     `json:"netstakeweight"`
		Expectedtime     int     `json:"expectedtime"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type DenariusListReceivedByAddressRespStruct struct {
	Result []struct {
		Address       string        `json:"address"`
		Amount        float64       `json:"amount"`
		Confirmations int           `json:"confirmations"`
		Label         string        `json:"label"`
		Txids         []interface{} `json:"txids"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type DenariusListTransactions struct {
	Result []struct {
		Account       string  `json:"account"`
		Address       string  `json:"address"`
		Category      string  `json:"category"`
		Amount        float64 `json:"amount,omitempty"`
		Vout          int     `json:"vout"`
		Label         string  `json:"label"`
		Version       int     `json:"version"`
		Confirmations int     `json:"confirmations"`
		Blockhash     string  `json:"blockhash"`
		Blockindex    int     `json:"blockindex"`
		Blocktime     int     `json:"blocktime"`
		Txid          string  `json:"txid"`
		Time          int     `json:"time"`
		Timereceived  int     `json:"timereceived"`
		Reward        float64 `json:"reward,omitempty"`
		Generated     bool    `json:"generated,omitempty"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type DenariusNewAddressStruct struct {
	Result string      `json:"result"`
	Error  interface{} `json:"error"`
	ID     string      `json:"id"`
}

type DenariusStakingInfoStruct struct {
	Result struct {
		Enabled          bool    `json:"enabled"`
		Staking          bool    `json:"staking"`
		Errors           string  `json:"errors"`
		Currentblocksize int     `json:"currentblocksize"`
		Currentblocktx   int     `json:"currentblocktx"`
		Pooledtx         int     `json:"pooledtx"`
		Difficulty       float64 `json:"difficulty"`
		SearchInterval   int     `json:"search-interval"`
		Weight           int     `json:"weight"`
		Netstakeweight   int     `json:"netstakeweight"`
		Expectedtime     int     `json:"expectedtime"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

//type DenariusWalletInfoRespStruct struct {
//	Result struct {
//		Walletname            string  `json:"walletname"`
//		Walletversion         int     `json:"walletversion"`
//		Balance               float64 `json:"balance"`
//		UnconfirmedBalance    float64 `json:"unconfirmed_balance"`
//		ImmatureBalance       float64 `json:"immature_balance"`
//		Txcount               int     `json:"txcount"`
//		Keypoololdest         int     `json:"keypoololdest"`
//		Keypoolsize           int     `json:"keypoolsize"`
//		Hdseedid              string  `json:"hdseedid"`
//		KeypoolsizeHdInternal int     `json:"keypoolsize_hd_internal"`
//		Paytxfee              float64 `json:"paytxfee"`
//		PrivateKeysEnabled    bool    `json:"private_keys_enabled"`
//		AvoidReuse            bool    `json:"avoid_reuse"`
//		Scanning              bool    `json:"scanning"`
//		UnlockedUntil         int     `json:"unlocked_until"`
//	} `json:"result"`
//	Error interface{} `json:"error"`
//	ID    string      `json:"id"`
//}

func GetBlockchainInfoDenarius(cliConf *ConfStruct) (DenariusBlockchainInfoRespStruct, error) {
	var respStruct DenariusBlockchainInfoRespStruct

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

func GetInfoDenarius(cliConf *ConfStruct) (DenariusGetInfoRespStruct, error) {
	var respStruct DenariusGetInfoRespStruct

	for i := 1; i < 50; i++ {
		//fmt.Printf("\r"+waitingStr+" %d/"+strconv.Itoa(attempts), i)
		body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + cCommandGetInfo + "\",\"params\":[]}")
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

		// Check to make sure we are not loading the wallet
		if bytes.Contains(bodyResp, []byte("Loading")) ||
			bytes.Contains(bodyResp, []byte("Rewinding")) ||
			bytes.Contains(bodyResp, []byte("Verifying")) {
			// The wallet is still loading, so print message, and sleep for 3 seconds and try again..
			var errStruct GenericRespStruct
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

func GetStakingInfoDenarius(cliConf *ConfStruct) (DenariusStakingInfoStruct, error) {
	var respStruct DenariusStakingInfoStruct

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + cCommandGetStakingInfo + "\",\"params\":[]}")
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

func GetInfoDenariusUI(cliConf *ConfStruct, spin *yacspin.Spinner) (DenariusGetInfoRespStruct, string, error) {
	var respStruct DenariusGetInfoRespStruct

	for i := 1; i < 600; i++ {
		body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + cCommandGetInfo + "\",\"params\":[]}")
		req, err := http.NewRequest("POST", "http://"+cliConf.ServerIP+":"+cliConf.Port, body)
		if err != nil {
			return respStruct, "", err
		}
		req.SetBasicAuth(cliConf.RPCuser, cliConf.RPCpassword)
		req.Header.Set("Content-Type", "text/plain;")

		resp, err := http.DefaultClient.Do(req)
		//defer resp.Body.Close()
		if err != nil {
			spin.Message(" waiting for your " + CCoinNameDenarius + " wallet to respond, this could take several minutes (ctrl-c to cancel)...")
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
				var errStruct GenericRespStruct
				err = json.Unmarshal(bodyResp, &errStruct)
				if err != nil {
					return respStruct, "", err
				}

				if bytes.Contains(bodyResp, []byte("Loading")) {
					spin.Message(" Your " + CCoinNameDenarius + " wallet is *Loading*, this could take a while...")
				} else if bytes.Contains(bodyResp, []byte("Rescanning")) {
					spin.Message(" Your " + CCoinNameDenarius + " wallet is *Rescanning*, this could take a while...")
				} else if bytes.Contains(bodyResp, []byte("Rewinding")) {
					spin.Message(" Your " + CCoinNameDenarius + " wallet is *Rewinding*, this could take a while...")
				} else if bytes.Contains(bodyResp, []byte("Verifying")) {
					spin.Message(" Your " + CCoinNameDenarius + " wallet is *Verifying*, this could take a while...")
				} else if bytes.Contains(bodyResp, []byte("Calculating money supply")) {
					spin.Message(" Your " + CCoinNameDenarius + " wallet is *Calculating money supply*, this could take a while...")
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

func GetNewAddressDenarius(cliConf *ConfStruct) (DenariusNewAddressStruct, error) {
	var respStruct DenariusNewAddressStruct

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getnewaddress\",\"params\":[]}")
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

func GetNetworkDifficultyTxtDenarius(difficulty, good, warn float64) string {
	var s string
	if difficulty > 1000 {
		s = humanize.FormatFloat("#.#", difficulty/1000) + "k"
	} else {
		s = humanize.Ftoa(difficulty)
	}

	// If Diff is less than 1, then we're not even calculating it properly yet...
	if difficulty < 1 {
		return "[Difficulty:  waiting...](fg:white)"
	}

	if difficulty >= good {
		return "Difficulty:  [" + s + "](fg:green)"
	} else if difficulty >= warn {
		return "Difficulty:  [" + s + "](fg:yellow)"
	} else {
		return "Difficulty:  [" + s + "](fg:red)"
	}
}

func GetWalletSecurityStateDenarius(gi *DenariusGetInfoRespStruct) WEType {
	if gi.Result.UnlockedUntil == 0 {
		return WETLocked
	} else if gi.Result.UnlockedUntil == -1 {
		return WETUnencrypted
	} else if gi.Result.UnlockedUntil > 0 {
		return WETUnlockedForStaking
	} else {
		return WETUnknown
	}
}

func ListReceivedByAddressDenarius(cliConf *ConfStruct, includeZero bool) (DenariusListReceivedByAddressRespStruct, error) {
	var respStruct DenariusListReceivedByAddressRespStruct

	var s string
	if includeZero {
		s = "{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"listreceivedbyaddress\",\"params\":[1, true]}"
	} else {
		s = "{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"listreceivedbyaddress\",\"params\":[1, false]}"
	}
	body := strings.NewReader(s)
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

func ListTransactionsDenarius(cliConf *ConfStruct) (DenariusListTransactions, error) {
	var respStruct DenariusListTransactions

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + cCommandListTransactions + "\",\"params\":[]}")
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
