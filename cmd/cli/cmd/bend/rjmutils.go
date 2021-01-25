package bend

import (
	"archive/tar"
	"archive/zip"
	"bufio"
	"compress/gzip"
	"errors"
	"fmt"
	"io"
	"io/ioutil"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

// rjmutils version 0.02

func addFileToZip(zipWriter *zip.Writer, filename string) error {

	fileToZip, err := os.Open(filename)
	if err != nil {
		return err
	}
	defer fileToZip.Close()

	// Get the file information
	info, err := fileToZip.Stat()
	if err != nil {
		return err
	}

	header, err := zip.FileInfoHeader(info)
	if err != nil {
		return err
	}

	// Using FileInfoHeader() above only uses the basename of the file. If we want
	// to preserve the folder structure we can overwrite this with the full path.
	header.Name = filename

	// Change to deflate to gain better compression
	// see http://golang.org/pkg/archive/zip/#pkg-constants
	header.Method = zip.Deflate

	writer, err := zipWriter.CreateHeader(header)
	if err != nil {
		return err
	}
	_, err = io.Copy(writer, fileToZip)
	return err
}

func AddToLog(logFile, txt string, toScreen bool) error {
	f, err := os.OpenFile(logFile,
		os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return err
	}
	defer f.Close()

	logger := log.New(f, "", log.LstdFlags)
	logger.Println(txt)
	if toScreen {
		fmt.Println(txt)
	}

	return nil
}

func AddTrailingSlash(filePath string) string {
	var lastChar = filePath[len(filePath)-1:]
	if IsWindows() {
		if lastChar == "\\" {
			return filePath
		} else {
			return filePath + "\\"
		}
	}
	if IsLinux() {
		if lastChar == "/" {
			return filePath
		} else {
			return filePath + "/"
		}
	}
	return ""
}

func ClearScreen() {
	if IsLinux() {
		cmd := exec.Command("clear") //Linux example, its tested
		cmd.Stdout = os.Stdout
		cmd.Run()
	}
	if IsWindows() {
		cmd := exec.Command("cmd", "/c", "cls") //Windows example, its tested
		cmd.Stdout = os.Stdout
		cmd.Run()
	}
}

// BackupFile - Copy file from srcFile to destFile, and display output if requested
func BackupFile(srcFolder, srcFile, dstFolder, prefixStr string, failOnNoSrc bool) error {
	dt := time.Now()
	dtStr := dt.Format("2006-01-02")

	if !FileExists(srcFolder + srcFile) {
		if failOnNoSrc {
			return errors.New(srcFolder + srcFile + " doesn't exist")
		} else {
			return nil
		}
	}

	// Open original file
	originalFile, err := os.Open(srcFolder + srcFile)
	if err != nil {
		return err
	}
	defer originalFile.Close()

	// Create new file.
	if dstFolder == "" {
		dstFolder = srcFolder
	}
	newFile, err := os.Create(dstFolder + prefixStr + "-" + dtStr + "-" + srcFile)
	if err != nil {
		return err
	}
	defer newFile.Close()

	// Copy the bytes to destination from source
	_, err = io.Copy(newFile, originalFile)
	if err != nil {
		return err
	}

	// Commit the file contents
	// Flushes memory to disk
	err = newFile.Sync()
	if err != nil {
		return err
	}

	return nil
}

func compressFilesInDir(dir, filespec string, removeSF bool) (compressedFile string, err error) {
	files, err := ioutil.ReadDir(dir)
	var fps []string
	if err != nil {
		return "", nil
	}

	for _, f := range files {
		if filepath.Ext(f.Name()) == (filepath.Ext(filespec)) {
			fmt.Println(f.Name())
			fps = append(fps, f.Name())
		}
	}
	t := time.Now()
	var tarfile string = t.Format("2006-01-02") + ".tar"
	createTarball("./"+tarfile, fps)
	if removeSF {
		for _, fs := range fps {
			err = os.Remove(fs)
			if err != nil {
				return "", nil
			}
		}
	}
	gFile, err := gZipIt(dir+tarfile, dir, true)
	if err != nil {
		return "", nil
	}
	if removeSF {
		err = os.Remove(dir + tarfile)
		if err != nil {
			return "", nil
		}
	}

	return dir + gFile, nil
}

// FileCopy - Copy file from srcFile to destFile, and display output if requested
func FileCopy(srcFile, destFile string, dispOutput bool) error {
	// Open original file
	originalFile, err := os.Open(srcFile)
	if err != nil {
		return err
	}
	defer originalFile.Close()

	// Create new file
	newFile, err := os.Create(destFile)
	if err != nil {
		return err
	}
	defer newFile.Close()

	// Copy the bytes to destination from source
	bytesWritten, err := io.Copy(newFile, originalFile)
	if err != nil {
		return err
	}
	if dispOutput {
		log.Printf("Copied %d bytes.", bytesWritten)
	}

	// Commit the file contents
	// Flushes memory to disk
	err = newFile.Sync()
	if err != nil {
		return err
	}

	return nil
}

func FileDelete(file string) error {
	err := os.Remove(file)
	if err != nil {
		return err
	}
	return nil
}

// fileExists checks if a file exists and is not a directory before we
// try using it to prevent further errors.
func FileExists(filename string) bool {
	info, err := os.Stat(filename)
	if os.IsNotExist(err) {
		return false
	}
	return !info.IsDir()
}

func dirSize(path string) (int64, error) {
	var size int64
	err := filepath.Walk(path, func(_ string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if !info.IsDir() {
			size += info.Size()
		}
		return err
	})
	return size, err
}

func getFunnyWaitingStr(index int) string {
	switch index {
	case 0:
		return "Waiting..."
	case 1:
		return "Still waiting..."
	case 2:
		return "Still waiting...?"
	case 3:
		return "Still waiting...!"
	case 4:
		return "STILL waiting......!"
	case 5:
		return "S..T..I..L..L.. waiting......!"
	case 6:
		return "Come.... on...!"
	case 7:
		return "How long is this going to take?..."
	case 8:
		return "Hello.....?"
	case 9:
		return "H..e..l..l..o...?"
	case 10:
		return "Seriously...?"
	case 11:
		return "How long can it possibly take...?"
	case 12:
		return "It was only one simple command..."
	case 13:
		return "Hang on..."
	case 14:
		return "I'll give it another kick..."
	case 15:
		return "Ooops...."
	case 16:
		return "...I might have kicked to hard..."
	case 17:
		return "Hello.....?"
	case 18:
		return "No, it's OK, there's signs of life..."
	case 19:
		return "I don't think this is going to work..."
	case 20:
		return "Let's try one more time..."
	case 21:
		return "Kick......?"
	case 22:
		return "No sorry, there's no life..."
	case 23:
		return "It's dead Jim..."
	}
	return "Waiting..."

}

func ExtractTarGz(gzipStream io.Reader) error {
	uncompressedStream, err := gzip.NewReader(gzipStream)
	if err != nil {
		log.Fatal("ExtractTarGz: NewReader failed")
	}

	tarReader := tar.NewReader(uncompressedStream)

	for true {
		header, err := tarReader.Next()

		if err == io.EOF {
			break
		}

		if err != nil {
			log.Fatalf("ExtractTarGz: Next() failed: %s", err.Error())
		}

		switch header.Typeflag {
		case tar.TypeDir:
			if err := os.Mkdir(header.Name, 0755); err != nil {
				log.Fatalf("ExtractTarGz: Mkdir() failed: %s", err.Error())
			}
		case tar.TypeReg:
			outFile, err := os.Create(header.Name)
			if err != nil {
				log.Fatalf("ExtractTarGz: Create() failed: %s", err.Error())
			}
			if _, err := io.Copy(outFile, tarReader); err != nil {
				log.Fatalf("ExtractTarGz: Copy() failed: %s", err.Error())
			}
			outFile.Close()

		default:
			log.Fatalf("ExtractTarGz: uknown type: %s in %s", header.Typeflag, header.Name)
		}

	}
	return nil
}

func ExtractTarGzWithDest(gzipStream io.Reader, destDir string) error {
	uncompressedStream, err := gzip.NewReader(gzipStream)
	if err != nil {
		log.Fatal("ExtractTarGz: NewReader failed")
	}

	tarReader := tar.NewReader(uncompressedStream)

	for true {
		header, err := tarReader.Next()

		if err == io.EOF {
			break
		}

		if err != nil {
			log.Fatalf("ExtractTarGz: Next() failed: %s", err.Error())
		}

		switch header.Typeflag {
		case tar.TypeDir:
			if err := os.Mkdir(destDir+header.Name, 0755); err != nil {
				log.Fatalf("ExtractTarGz: Mkdir() failed: %s", err.Error())
			}
		case tar.TypeReg:
			outFile, err := os.Create(destDir + header.Name)
			if err != nil {
				log.Fatalf("ExtractTarGz: Create() failed: %s", err.Error())
			}
			if _, err := io.Copy(outFile, tarReader); err != nil {
				log.Fatalf("ExtractTarGz: Copy() failed: %s", err.Error())
			}
			outFile.Close()

		default:
			log.Fatalf("ExtractTarGz: uknown type: %s in %s", header.Typeflag, header.Name)
		}

	}
	return nil
}

// GetRunningDir - Return the directory of the running binary
func GetRunningDir() (string, error) {
	ex, err := os.Executable()
	if err != nil {
		return "", err
	}
	exPath := filepath.Dir(ex)
	sdir := AddTrailingSlash(exPath)
	return sdir, err

}

func gZipIt(sourceFile, targetDir string, deleteOrig bool) (gzFile string, err error) {
	log.Print("GZipping file " + sourceFile + "...")
	reader, err := os.Open(sourceFile)
	if err != nil {
		return "", err
	}

	filename := filepath.Base(sourceFile)
	var targetFile string = filepath.Join(targetDir, fmt.Sprintf("%s.gz", filename))
	writer, err := os.Create(targetFile)
	if err != nil {
		return "", err
	}
	defer writer.Close()

	archiver := gzip.NewWriter(writer)
	archiver.Name = filename
	defer archiver.Close()

	_, err = io.Copy(archiver, reader)
	if err != nil {
		return "", err
	}
	if deleteOrig {
		log.Print("Removing source file " + sourceFile + "...")
		err = os.Remove(sourceFile)
		if err != nil {
			return "", err
		}
	}

	return targetFile, err
}

func IsWindows() bool {
	if runtime.GOOS == "windows" {
		return true
	}
	return false
}

func IsLinux() bool {
	if runtime.GOOS == "linux" {
		return true
	}
	return false
}

func createTarball(tarballFilePath string, filePaths []string) error {
	file, err := os.Create(tarballFilePath)
	if err != nil {
		return errors.New(fmt.Sprintf("Could not create tarball file '%s', got error '%s'", tarballFilePath, err.Error()))
	}
	defer file.Close()

	gzipWriter := gzip.NewWriter(file)
	defer gzipWriter.Close()

	tarWriter := tar.NewWriter(gzipWriter)
	defer tarWriter.Close()

	for _, filePath := range filePaths {
		err := addFileToTarWriter(filePath, tarWriter)
		if err != nil {
			return errors.New(fmt.Sprintf("Could not add file '%s', to tarball, got error '%s'", filePath, err.Error()))
		}
	}

	return nil
}

func GetStrAfterStr(value string, a string) string {
	// Get substring after a string.
	pos := strings.LastIndex(value, a)
	if pos == -1 {
		return ""
	}
	adjustedPos := pos + len(a)
	if adjustedPos >= len(value) {
		return ""
	}
	return value[adjustedPos:len(value)]
}

// GetStringAfterStrFromFile - Returns the string after the passed string: e.g line in file is "greeting=hi", if the stringToFind was "greeting=" it would return "hi""
func GetStringAfterStrFromFile(stringToFind, file string) (string, error) {
	if !FileExists(file) {
		return "", nil
	}

	data, err := ioutil.ReadFile(file)
	if err != nil {
		log.Fatal(err)
	}
	scanner := bufio.NewScanner(strings.NewReader(string(data)))
	for scanner.Scan() {
		s := scanner.Text()
		if strings.Contains(s, stringToFind) {
			t := GetStrAfterStr(s, "=") //strings.Replace(s,stringToFind,"", -1)
			return t, nil
		}
	}
	return "", nil

}

func StringExistsInFile(str, file string) (bool, error) {
	if !FileExists(file) {
		return false, nil
	}

	data, err := ioutil.ReadFile(file)
	if err != nil {
		log.Fatal(err)
	}
	scanner := bufio.NewScanner(strings.NewReader(string(data)))
	for scanner.Scan() {
		s := scanner.Text()
		if strings.Contains(s, str) {
			return true, nil
		}
	}
	return false, nil
}

func addFileToTarWriter(filePath string, tarWriter *tar.Writer) error {
	file, err := os.Open(filePath)
	if err != nil {
		return errors.New(fmt.Sprintf("Could not open file '%s', got error '%s'", filePath, err.Error()))
	}
	defer file.Close()

	stat, err := file.Stat()
	if err != nil {
		return errors.New(fmt.Sprintf("Could not get stat for file '%s', got error '%s'", filePath, err.Error()))
	}

	header := &tar.Header{
		Name:    filePath,
		Size:    stat.Size(),
		Mode:    int64(stat.Mode()),
		ModTime: stat.ModTime(),
	}

	err = tarWriter.WriteHeader(header)
	if err != nil {
		return errors.New(fmt.Sprintf("Could not write header for file '%s', got error '%s'", filePath, err.Error()))
	}

	_, err = io.Copy(tarWriter, file)
	if err != nil {
		return errors.New(fmt.Sprintf("Could not copy the file '%s' data to the tarball, got error '%s'", filePath, err.Error()))
	}

	return nil
}

func unGZip(source, target string) error {
	reader, err := os.Open(source)
	if err != nil {
		return err
	}
	defer reader.Close()

	archive, err := gzip.NewReader(reader)
	if err != nil {
		return err
	}
	defer archive.Close()

	target = filepath.Join(target, archive.Name)
	writer, err := os.Create(target)
	if err != nil {
		return err
	}
	defer writer.Close()

	_, err = io.Copy(writer, archive)
	return err
}

// Unzip will decompress a zip archive, moving all files and folders
// within the zip file (parameter 1) to an output directory (parameter 2).
func UnZip(src string, dest string) ([]string, error) {

	var filenames []string

	r, err := zip.OpenReader(src)
	if err != nil {
		return filenames, err
	}
	defer r.Close()

	for _, f := range r.File {

		// Store filename/path for returning and using later on
		fpath := filepath.Join(dest, f.Name)

		// Check for ZipSlip. More Info: http://bit.ly/2MsjAWE
		if !strings.HasPrefix(fpath, filepath.Clean(dest)+string(os.PathSeparator)) {
			return filenames, fmt.Errorf("%s: illegal file path", fpath)
		}

		filenames = append(filenames, fpath)

		if f.FileInfo().IsDir() {
			// Make Folder
			os.MkdirAll(fpath, os.ModePerm)
			continue
		}

		// Make File
		if err = os.MkdirAll(filepath.Dir(fpath), os.ModePerm); err != nil {
			return filenames, err
		}

		outFile, err := os.OpenFile(fpath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, f.Mode())
		if err != nil {
			return filenames, err
		}

		rc, err := f.Open()
		if err != nil {
			return filenames, err
		}

		_, err = io.Copy(outFile, rc)

		// Close the file without defer to close before next iteration of loop
		outFile.Close()
		rc.Close()

		if err != nil {
			return filenames, err
		}
	}
	return filenames, nil
}

func Untartar(tarName, xpath string) (err error) {
	tarFile, err := os.Open(tarName)
	defer tarFile.Close()
	absPath, err := filepath.Abs(xpath)
	tr := tar.NewReader(tarFile)

	// enable compression if file ends in .gz
	tw := tar.NewWriter(tarFile)
	if strings.HasSuffix(tarName, ".gz") {
		gz := gzip.NewWriter(tarFile)
		defer gz.Close()
		tw = tar.NewWriter(gz)
	}
	defer tw.Close()
	// untar each segment
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
		// determine proper file path info
		finfo := hdr.FileInfo()
		fileName := hdr.Name
		absFileName := filepath.Join(absPath, fileName)
		// if a dir, create it, then go to next segment
		if finfo.Mode().IsDir() {
			if err := os.MkdirAll(absFileName, 0755); err != nil {
				return err
			}
			continue
		}
		// create new file with original file mode
		file, err := os.OpenFile(
			absFileName,
			os.O_RDWR|os.O_CREATE|os.O_TRUNC,
			finfo.Mode().Perm(),
		)
		if err != nil {
			return err
		}
		fmt.Printf("x %s\n", absFileName)
		n, cpErr := io.Copy(file, tr)
		if closeErr := file.Close(); closeErr != nil {
			return err
		}
		if cpErr != nil {
			return cpErr
		}
		if n != finfo.Size() {
			return fmt.Errorf("wrote %d, want %d", n, finfo.Size())
		}
	}
	return nil
}

func Unzip2(src, dest string) error {
	r, err := zip.OpenReader(src)
	if err != nil {
		return err
	}
	defer func() {
		if err := r.Close(); err != nil {
			panic(err)
		}
	}()

	os.MkdirAll(dest, 0755)

	// Closure to address file descriptors issue with all the deferred .Close() methods
	extractAndWriteFile := func(f *zip.File) error {
		rc, err := f.Open()
		if err != nil {
			return err
		}
		defer func() {
			if err := rc.Close(); err != nil {
				panic(err)
			}
		}()

		path := filepath.Join(dest, f.Name)

		// Check for ZipSlip (Directory traversal)
		if !strings.HasPrefix(path, filepath.Clean(dest)+string(os.PathSeparator)) {
			return fmt.Errorf("illegal file path: %s", path)
		}

		if f.FileInfo().IsDir() {
			os.MkdirAll(path, f.Mode())
		} else {
			os.MkdirAll(filepath.Dir(path), f.Mode())
			f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, f.Mode())
			if err != nil {
				return err
			}
			defer func() {
				if err := f.Close(); err != nil {
					panic(err)
				}
			}()

			_, err = io.Copy(f, rc)
			if err != nil {
				return err
			}
		}
		return nil
	}

	for _, f := range r.File {
		err := extractAndWriteFile(f)
		if err != nil {
			return err
		}
	}

	return nil
}

func WriteTextToFile(fileName, text string) error {
	// Open a new file for writing only
	file, err := os.OpenFile(
		fileName,
		os.O_WRONLY|os.O_APPEND|os.O_CREATE,
		0666,
	)
	if err != nil {
		return err
	}
	defer file.Close()

	// Write bytes to file
	byteSlice := []byte(text + "\n")
	_, err = file.Write(byteSlice)
	if err != nil {
		return err
	}
	//log.Printf("Wrote %d bytes.\n", bytesWritten)

	return nil
}

// zipFiles compresses one or many files into a single zip archive file.
// Param 1: filename is the output zip file's name.
// Param 2: files is a list of files to add to the zip.
func zipFiles(filename string, files []string) error {

	newZipFile, err := os.Create(filename)
	if err != nil {
		return err
	}
	defer newZipFile.Close()

	zipWriter := zip.NewWriter(newZipFile)
	defer zipWriter.Close()

	// Add files to zip
	for _, file := range files {
		if err = addFileToZip(zipWriter, file); err != nil {
			return err
		}
	}
	return nil
}
