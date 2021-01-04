package bend

import (
	"encoding/json"
	"io/ioutil"
	"os"
	//be "richardmace.co.uk/boxwallet/cmd/cli/cmd/bend"
	"runtime"
)

const (
	CConfFile    string = "conf"
	CConfFileExt string = ".json"
)

type ConfStruct struct {
	BinFolder             string      // The folder that contains the coin binary files
	Currency              string      // USD, GBP
	FirstTimeRun          bool        // Is this the first time the server has run? If so, we need to store the BinFolder
	ProjectType           ProjectType // The project type
	Port                  string      // The port that the server should run on
	RefreshTimer          int         // Refresh interval
	RPCuser               string      // The rpcuser
	RPCpassword           string      // The rpc password
	ServerIP              string      // The IP address of the coin daemon server
	UserConfirmedWalletBU bool        // Whether or not the user has said they've stored their recovery seed has been stored
}

func addTrailingSlash(filePath string) string {
	var lastChar = filePath[len(filePath)-1:]
	if runtime.GOOS == "windows" {
		if lastChar == "\\" {
			return filePath
		} else {
			return filePath + "\\"
		}
	} else {
		if lastChar == "/" {
			return filePath
		} else {
			return filePath + "/"
		}
	}
	//return ""
}

func createDefaultConfFile(confDir string) error {
	var conf = newConfStruct()

	jssb, err := json.MarshalIndent(conf, "", "  ")
	if err != nil {
		return err
	}

	f, err := os.Create(confDir + CConfFile + CConfFileExt)
	if err != nil {
		return err
	}

	//log.Println("Creating default conf file " + f.Name())
	_, err = f.WriteString(string(jssb))
	err = f.Close()
	if err != nil {
		return err
	}
	return nil
}

// GetConfigStruct
func GetConfigStruct(confDir string, refreshFields bool) (ConfStruct, error) {
	// If the passed in confDir is blank, then assume current working directory
	//dir := ""
	if confDir == "" {
		confDir, _ = GetAppWorkingFolder() // os.Getwd()
	}

	confDir = addTrailingSlash(confDir)

	// Create the file if it doesn't already exist
	if _, err := os.Stat(confDir + CConfFile + CConfFileExt); os.IsNotExist(err) {
		if err := createDefaultConfFile(confDir); err != nil {
			return ConfStruct{}, err
		}
	}

	// Get the config file
	file, err := ioutil.ReadFile(confDir + CConfFile + CConfFileExt)
	if err != nil {
		return ConfStruct{}, err
	}

	cs := ConfStruct{}

	err = json.Unmarshal([]byte(file), &cs)
	if err != nil {
		return ConfStruct{}, err
	}

	// Now, let's write the file back because it may have some new fields
	if refreshFields {
		if err := SetConfigStruct(confDir, cs); err != nil {
			return ConfStruct{}, err
		}
	}

	return cs, nil
}

func newConfStruct() ConfStruct {
	cnf := ConfStruct{}
	cnf.BinFolder = ""
	cnf.Currency = "USD"
	cnf.FirstTimeRun = true
	cnf.ProjectType = 0
	cnf.RefreshTimer = 3
	cnf.RPCuser = ""
	cnf.RPCpassword = ""
	cnf.ServerIP = "127.0.0.1"
	cnf.Port = ""
	cnf.UserConfirmedWalletBU = false

	return cnf
}

func SetConfigStruct(confDir string, cs ConfStruct) error {
	if confDir == "" {
		confDir, _ = GetAppWorkingFolder() //os.Getwd()
	}

	// If the passed in confDir is blank, then assume current working directory
	//dir, err := os.Getwd()
	//if err != nil {
	//	return err
	//}

	jssb, _ := json.MarshalIndent(cs, "", "  ")
	confDir = addTrailingSlash(confDir)
	sFile := confDir + CConfFile + CConfFileExt

	f, err := os.Create(sFile)
	if err != nil {
		return err
	}

	_, err = f.WriteString(string(jssb))
	err = f.Close()
	if err != nil {
		return err
	}
	return nil
}
