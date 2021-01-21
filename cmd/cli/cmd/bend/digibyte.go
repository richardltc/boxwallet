package bend

const (
	CCoinNameDigiByte string = "DigiByte"

	CDigiByteCoreVersion string = "7.17.2"
	CDFDigiByteArm64     string = "digibyte-" + CDigiByteCoreVersion + "-aarch64-linux-gnu.tar.gz"
	CDFDigiByteLinux     string = "digibyte-" + CDigiByteCoreVersion + "-x86_64-linux-gnu.tar.gz"
	CDFDigiByteWindows   string = "digibyte-" + CDigiByteCoreVersion + "-win64.zip"

	CDigiByteExtractedDirLinux   = "digibyte-" + CDigiByteCoreVersion + "/"
	CDigiByteExtractedDirWindows = "digibyte-" + CDigiByteCoreVersion + "\\"

	CDownloadURLDigiByte string = "https://github.com/digibyte/digibyte/releases/download/v" + CDigiByteCoreVersion + "/"

	CDigiByteHomeDir    string = ".digibyte"
	CDigiByteHomeDirWin string = "DIGIBYTE"

	CDigiByteConfFile   string = "digibyte.conf"
	CDigiByteCliFile    string = "digibyte-cli"
	CDigiByteCliFileWin string = "digibyte-cli.exe"
	CDigiByteDFile      string = "digibyted"
	CDigiByteDFileWin   string = "digibyted.exe"
	CDigiByteTxFile     string = "digibyte-tx"
	CDigiByteTxFileWin  string = "digibyte-tx.exe"

	CDigiByteRPCPort string = "14022"
)
