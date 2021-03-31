package bend

import (
	"bytes"
	"encoding/json"
	"github.com/dustin/go-humanize"
	"github.com/theckman/yacspin"
	"io/ioutil"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const (
	CCoinNameDigiByte   string = "DigiByte"
	CCoinAbbrevDigiByte string = "DGB"

	CCoreVersionDigiByte string = "7.17.2"
	CDFArm64DigiByte     string = "digibyte-" + CCoreVersionDigiByte + "-aarch64-linux-gnu.tar.gz"
	CDFLinuxDigiByte     string = "digibyte-" + CCoreVersionDigiByte + "-x86_64-linux-gnu.tar.gz"
	CDFWindowsDigiByte   string = "digibyte-" + CCoreVersionDigiByte + "-win64.zip"

	CExtractedDirLinuxDigiByte   = "digibyte-" + CCoreVersionDigiByte + "/"
	CExtractedDirWindowsDigiByte = "digibyte-" + CCoreVersionDigiByte + "\\"

	CDownloadURLDigiByte string = "https://github.com/digibyte/digibyte/releases/download/v" + CCoreVersionDigiByte + "/"

	cHomeDirLinDigiByte string = ".digibyte"
	cHomeDirWinDigiByte string = "DIGIBYTE"

	CConfFileDigiByte   string = "digibyte.conf"
	CCliFileDigiByte    string = "digibyte-cli"
	CCliFileWinDigiByte string = "digibyte-cli.exe"
	CDFileDigiByte      string = "digibyted"
	CDFileWinDigiByte   string = "digibyted.exe"
	CTxFileDigiByte     string = "digibyte-tx"
	CTxFileWinDigiByte  string = "digibyte-tx.exe"

	cRPCUserDigiByte string = "digibyterpc"
	CRPCPortDigiByte string = "14022"
)

// No GetInfo in DigiByte
// This call was removed in version 6.16.0. Use the appropriate fields from:
// getblockchaininfo: blocks, difficulty, chain
// getnetworkinfo: version, protocolversion, timeoffset, connections, proxy, relayfee, warnings
// getwalletinfo: balance, keypoololdest, keypoolsize, paytxfee, unlocked_until, walletversion

type DGBBlockchainInfoRespStruct struct {
	Result struct {
		Chain                string  `json:"chain"`
		Blocks               int     `json:"blocks"`
		Headers              int     `json:"headers"`
		Bestblockhash        string  `json:"bestblockhash"`
		Mediantime           int     `json:"mediantime"`
		Verificationprogress float64 `json:"verificationprogress"`
		Initialblockdownload bool    `json:"initialblockdownload"`
		Chainwork            string  `json:"chainwork"`
		SizeOnDisk           int     `json:"size_on_disk"`
		Pruned               bool    `json:"pruned"`
		Difficulties         struct {
			Scrypt float64 `json:"scrypt"`
		} `json:"difficulties"`
		Softforks     []interface{} `json:"softforks"`
		Bip9Softforks struct {
			Csv struct {
				Status    string `json:"status"`
				StartTime int    `json:"startTime"`
				Timeout   int    `json:"timeout"`
				Since     int    `json:"since"`
			} `json:"csv"`
			Segwit struct {
				Status    string `json:"status"`
				StartTime int    `json:"startTime"`
				Timeout   int    `json:"timeout"`
				Since     int    `json:"since"`
			} `json:"segwit"`
			Nversionbips struct {
				Status    string `json:"status"`
				StartTime int    `json:"startTime"`
				Timeout   int    `json:"timeout"`
				Since     int    `json:"since"`
			} `json:"nversionbips"`
			Reservealgo struct {
				Status    string `json:"status"`
				StartTime int    `json:"startTime"`
				Timeout   int    `json:"timeout"`
				Since     int    `json:"since"`
			} `json:"reservealgo"`
			Odo struct {
				Status    string `json:"status"`
				StartTime int    `json:"startTime"`
				Timeout   int    `json:"timeout"`
				Since     int    `json:"since"`
			} `json:"odo"`
		} `json:"bip9_softforks"`
		Warnings string `json:"warnings"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type DGBGetNewAddressStruct struct {
	Result string      `json:"result"`
	Error  interface{} `json:"error"`
	ID     string      `json:"id"`
}

type DGBListReceivedByAddressRespStruct struct {
	Result []struct {
		Address       string        `json:"address"`
		Account       string        `json:"account"`
		Amount        float64       `json:"amount"`
		Confirmations int           `json:"confirmations"`
		Label         string        `json:"label"`
		Txids         []interface{} `json:"txids"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type DGBListTransactions struct {
	Result []struct {
		Address         string        `json:"address"`
		Amount          float64       `json:"amount"`
		Vout            int           `json:"vout"`
		Category        string        `json:"category"`
		Confirmations   int           `json:"confirmations"`
		Txid            string        `json:"txid"`
		Walletconflicts []interface{} `json:"walletconflicts"`
		Time            int           `json:"time"`
		Timereceived    int           `json:"timereceived"`
		Blockhash       string        `json:"blockhash,omitempty"`
		Blockindex      int           `json:"blockindex,omitempty"`
		Blocktime       int           `json:"blocktime,omitempty"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type DGBNetworkInfoRespStruct struct {
	Result struct {
		Version         int    `json:"version"`
		Subversion      string `json:"subversion"`
		Protocolversion int    `json:"protocolversion"`
		Localservices   string `json:"localservices"`
		Localrelay      bool   `json:"localrelay"`
		Timeoffset      int    `json:"timeoffset"`
		Networkactive   bool   `json:"networkactive"`
		Connections     int    `json:"connections"`
		Networks        []struct {
			Name                      string `json:"name"`
			Limited                   bool   `json:"limited"`
			Reachable                 bool   `json:"reachable"`
			Proxy                     string `json:"proxy"`
			ProxyRandomizeCredentials bool   `json:"proxy_randomize_credentials"`
		} `json:"networks"`
		Relayfee       float64       `json:"relayfee"`
		Incrementalfee float64       `json:"incrementalfee"`
		Localaddresses []interface{} `json:"localaddresses"`
		Warnings       string        `json:"warnings"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type DGBWalletInfoRespStruct struct {
	Result struct {
		Walletname            string  `json:"walletname"`
		Walletversion         int     `json:"walletversion"`
		Balance               float64 `json:"balance"`
		UnconfirmedBalance    float64 `json:"unconfirmed_balance"`
		ImmatureBalance       float64 `json:"immature_balance"`
		Txcount               int     `json:"txcount"`
		Keypoololdest         int     `json:"keypoololdest"`
		Keypoolsize           int     `json:"keypoolsize"`
		KeypoolsizeHdInternal int     `json:"keypoolsize_hd_internal"`
		Paytxfee              float64 `json:"paytxfee"`
		Hdseedid              string  `json:"hdseedid"`
		Hdmasterkeyid         string  `json:"hdmasterkeyid"`
		UnlockedUntil         int     `json:"unlocked_until"`
		PrivateKeysEnabled    bool    `json:"private_keys_enabled"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

func GetBlockchainInfoDGB(cliConf *ConfStruct) (DGBBlockchainInfoRespStruct, error) {
	var respStruct DGBBlockchainInfoRespStruct

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + cCommandGetBCInfo + "\",\"params\":[]}")
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

func GetNetworkBlocksTxtDGB(bci *DGBBlockchainInfoRespStruct) string {
	blocksStr := humanize.Comma(int64(bci.Result.Blocks))

	if blocksStr == "0" {
		return "Blocks:      [waiting...](fg:white)"
	}

	return "Blocks:      [" + blocksStr + "](fg:green)"

}

func GetNetworkConnectionsTxtDGB(connections int) string {
	if connections == 0 {
		return "Peers:       [0](fg:red)"
	}
	return "Peers:       [" + strconv.Itoa(connections) + "](fg:green)"
}

func GetNetworkDifficultyTxtDGB(difficulty, good, warn float64) string {
	var s string
	if difficulty > 1000 {
		s = humanize.FormatFloat("#.#", difficulty/1000) + "k"
	} else {
		s = humanize.Ftoa(difficulty)
	}

	// If Diff is less than 1, then we're not even calculating it properly yet..
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

func GetNetworkHeadersTxtDGB(bci *DGBBlockchainInfoRespStruct) string {
	headersStr := humanize.Comma(int64(bci.Result.Headers))

	if bci.Result.Headers > 1 {
		return "Headers:     [" + headersStr + "](fg:green)"
	} else {
		return "[Headers:     " + headersStr + "](fg:red)"
	}
}

func GetNetworkInfoDGB(cliConf *ConfStruct) (DGBNetworkInfoRespStruct, error) {
	var respStruct DGBNetworkInfoRespStruct

	for i := 1; i < 50; i++ {
		body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + cCommandGetNetworkInfo + "\",\"params\":[]}")

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
			bytes.Contains(bodyResp, []byte("Rescanning")) ||
			bytes.Contains(bodyResp, []byte("Rewinding")) ||
			bytes.Contains(bodyResp, []byte("Verifying")) {
			// The wallet is still loading, so print message, and sleep for 3 seconds and try again
			time.Sleep(5 * time.Second)
		} else {
			_ = json.Unmarshal(bodyResp, &respStruct)
			return respStruct, err
		}
	}
	return respStruct, nil
}

func GetNetworkInfoDGBUI(cliConf *ConfStruct, spin *yacspin.Spinner) (DGBNetworkInfoRespStruct, string, error) {
	var respStruct DGBNetworkInfoRespStruct

	for i := 1; i < 600; i++ {
		body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + cCommandGetNetworkInfo + "\",\"params\":[]}")
		req, err := http.NewRequest("POST", "http://"+cliConf.ServerIP+":"+cliConf.Port, body)
		if err != nil {
			return respStruct, "", err
		}
		req.SetBasicAuth(cliConf.RPCuser, cliConf.RPCpassword)
		req.Header.Set("Content-Type", "text/plain;")

		for j := 1; j < 60; j++ {
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				spin.Message(" waiting for your " + CCoinNameDigiByte + " wallet to respond, this could take several minutes (ctrl-c to cancel)...")
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
				var errStruct GenericRespStruct
				err = json.Unmarshal(bodyResp, &errStruct)
				if err != nil {
					return respStruct, "", err
				}

				if bytes.Contains(bodyResp, []byte("Loading")) {
					spin.Message(" Your " + CCoinNameDigiByte + " wallet is currently Loading, this could take several minutes...")
				} else if bytes.Contains(bodyResp, []byte("Rescanning")) {
					spin.Message(" Your " + CCoinNameDigiByte + " wallet is currently Rescanning, this could take several minutes...")
				} else if bytes.Contains(bodyResp, []byte("Rewinding")) {
					spin.Message(" Your " + CCoinNameDigiByte + " wallet is currently Rewinding, this could take several minutes...")
				} else if bytes.Contains(bodyResp, []byte("Verifying")) {
					spin.Message(" Your " + CCoinNameDigiByte + " wallet is currently Verifying, this could take several minutes...")
				} else if bytes.Contains(bodyResp, []byte("Calculating money supply")) {
					spin.Message(" Your " + CCoinNameDigiByte + " wallet is currently Calculating money supply, this could take several minutes...")
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

func GetNewAddressDGB(cliConf *ConfStruct) (DGBGetNewAddressStruct, error) {
	var respStruct DGBGetNewAddressStruct

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + cCommandGetNewAddress + "\",\"params\":[]}")
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

func GetWalletInfoDGB(cliConf *ConfStruct) (DGBWalletInfoRespStruct, error) {
	var respStruct DGBWalletInfoRespStruct

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + cCommandGetWalletInfo + "\",\"params\":[]}")
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

	// Check to see if the json response contains "unlocked_until"
	s := string(bodyResp)
	if !strings.Contains(s, "unlocked_until") {
		respStruct.Result.UnlockedUntil = -1
	}

	return respStruct, nil
}

func GetWalletSecurityStateDGB(wi *DGBWalletInfoRespStruct) WEType {
	if wi.Result.UnlockedUntil == 0 {
		return WETLocked
	} else if wi.Result.UnlockedUntil == -1 {
		return WETUnencrypted
	} else if wi.Result.UnlockedUntil > 0 {
		return WETUnlockedForStaking
	} else {
		return WETUnknown
	}
}

func ListReceivedByAddressDGB(cliConf *ConfStruct, includeZero bool) (DGBListReceivedByAddressRespStruct, error) {
	var respStruct DGBListReceivedByAddressRespStruct

	var s string
	if includeZero {
		s = "{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"" + cCommandListReceivedByAddress + "\",\"params\":[1, true]}"
	} else {
		s = "{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"" + cCommandListReceivedByAddress + "\",\"params\":[1, false]}"
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

func ListTransactionsDGB(cliConf *ConfStruct) (DGBListTransactions, error) {
	var respStruct DGBListTransactions

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

func UnlockWalletDGB(cliConf *ConfStruct, pw string) error {
	var respStruct GenericRespStruct

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"walletpassphrase\",\"params\":[\"" + pw + "\",0]}")
	req, err := http.NewRequest("POST", "http://"+cliConf.ServerIP+":"+cliConf.Port, body)
	if err != nil {
		return err
	}
	req.SetBasicAuth(cliConf.RPCuser, cliConf.RPCpassword)
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
