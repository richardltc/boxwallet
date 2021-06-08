package conf

import (
	"encoding/json"
	"io/ioutil"
	"os"

	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
	"runtime"
)

type Conf struct {
	workingDir string
}

const (
	cConfFile string = "conf.json"
	cUnknown  string = "Unknown"
)

func (c *Conf) Bootstrap(workingDir string) {
	c.workingDir = addTrailingSlash(workingDir)
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
}

func (c *Conf) createDefaultConfFile() error {
	var conf = newConfStruct()

	jssb, err := json.MarshalIndent(conf, "", "  ")
	if err != nil {
		return err
	}

	f, err := os.Create(c.workingDir + cConfFile)
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

func (c *Conf) ConfFile() string {
	return cConfFile
}

// GetConfigStruct
func (c *Conf) GetConfig(refreshFields bool) (models.Conf, error) {
	var conf models.Conf
	// Create the file if it doesn't already exist
	if _, err := os.Stat(c.workingDir + cConfFile); os.IsNotExist(err) {
		if err := c.createDefaultConfFile(); err != nil {
			return conf, err
		}
	}

	// Get the config file
	file, err := ioutil.ReadFile(c.workingDir + cConfFile)
	if err != nil {
		return conf, err
	}

	err = json.Unmarshal([]byte(file), &conf)
	if err != nil {
		return conf, err
	}

	// Now, let's write the file back because it may have some new fields
	if refreshFields {
		if err := c.SetConfig(conf); err != nil {
			return conf, err
		}
	}

	return conf, nil
}

func newConfStruct() models.Conf {
	var cnf models.Conf
	//cnf.BinFolder = ""
	cnf.BlockchainSynced = false
	cnf.Currency = "USD"
	cnf.FirstTimeRun = true
	cnf.ProjectType = 0
	cnf.PerformHealthCheck = false
	cnf.LastHealthCheck = cUnknown
	cnf.RunHealthCheckAt = "01:15"
	cnf.RefreshTimer = 3
	cnf.RPCuser = ""
	cnf.RPCpassword = ""
	cnf.ServerIP = "127.0.0.1"
	cnf.Port = ""
	cnf.UserConfirmedWalletBU = false

	return cnf
}

func (c *Conf) SetConfig(conf models.Conf) error {
	jssb, _ := json.MarshalIndent(conf, "", "  ")
	sFile := c.workingDir + cConfFile

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
