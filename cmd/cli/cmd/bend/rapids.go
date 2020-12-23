package bend

const (
	CCoinNameRapids string = "Rapids"

	CRapidsCoreVersion string = "3.4"

	CDFRapidsFileRPi   string = "rapids-" + CRapidsCoreVersion + "-arm64.tar.gz"
	CDFRapidsFileLinux string = "rapids-" + CRapidsCoreVersion + "-lin64.tgz"
	//CDFRapidsFileLinuxDaemon string = "rapids-" + CRapidsCoreVersion + "-daemon-ubuntu1804.tar.gz"
	CDFRapidsFileWindows string = "rapids-" + CRapidsCoreVersion + "-win64.zip"

	CRapidsExtractedDirLinux = "rapids-" + CRapidsCoreVersion + "-lin64" + "/"
	//CRapidsExtractedDirDaemon  = "Rapids-" + CRapidsCoreVersion + "-daemon-ubuntu1804" + "/"
	CRapidsExtractedDirWindows = "rapids-4.3-win64" + "\\"

	CDownloadURLRapids string = "https://github.com/RapidsOfficial/Rapids/releases/download/v" + CRapidsCoreVersion + "/"

	cRapidsHomeDir    string = ".rapids"
	cRapidsHomeDirWin string = "RAPIDS"

	CRapidsConfFile   string = "rapids.conf"
	CRapidsCliFile    string = "rapids-cli"
	CRapidsCliFileWin string = "rapids-cli.exe"
	CRapidsDFile      string = "rapidsd"
	CRapidsDFileWin   string = "rapidsd.exe"
	CRapidsTxFile     string = "rapids-tx"
	CRapidsTxFileWin  string = "rapids-tx.exe"

	cRapidsRPCUser string = "rapidsrpc"
	CRapidsRPCPort string = "28732"
)

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
