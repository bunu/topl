package infer;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.io.IOException;
import java.nio.file.attribute.BasicFileAttributes;
import java.nio.file.FileAlreadyExistsException;
import java.nio.file.Files;
import java.nio.file.FileSystem;
import java.nio.file.FileSystems;
import java.nio.file.FileVisitResult;
import java.nio.file.Path;
import java.nio.file.SimpleFileVisitor;
import java.nio.file.StandardCopyOption;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/*
Infer can call a custom compiler as long as it is implemented as a jar file,
using the option --java-jar-compiler. The current class is intended to be used
as a 'compiler' that
  1. calls javac and save its stderr
    - saves output to outDir, which is either what comes after -d,
      or a temporary one
  2. calls toplc to instrument the classes generated by javac
    - mv outDir inDir  (where inDir is a temp dir)
    - toplc -s -i inDir -o outDir props.topl
  3. prints the stderr produced in step (1) by javac.
    - also fake Property.java and Property.class (in outDir)

Sometimes the user wants to provide a wrapper that initializes the TOPL property
and then runs the main function of the project being verified. To facilitate
this, file names ending in ".java.topl" are stripped of ".topl" and then sent to
toplc in the -e option. In other words, they get compiled after toplc generates
the monitor, because they refer to it.
*/
public class Compile {
  public static void main(String[] args)
  {
    try { go(args); }
    catch (Exception e) {
      e.printStackTrace();
      bail(String.format("Exception (%s).", e));
    }
  }

  static void go(String[] args) throws IOException, InterruptedException {
    // === Step 1 ===
    List<String> toplJava = new ArrayList<>();
    List<String> toplProperties = new ArrayList<>();
    List<String> javacArgs = expandArgFile(args);
    { List<String> xs = new ArrayList<>();
      for (String a : javacArgs) {
        if (a.endsWith(".java.topl")) {
          toplJava.add(a.substring(0, a.length() - ".topl".length()));
        } else if (a.endsWith(".topl")) {
          toplProperties.add(a);
        } else {
          xs.add(a);
        }
      }
      javacArgs = xs;
    }

    Path outDirPath = null;
    { String outDirName = null;
      boolean previousIsD = false;
      List<String> xs = new ArrayList<>();
      for (String a : javacArgs) {
        if (previousIsD) {
          outDirName = a;
          previousIsD = false;
        } else if ("-d".equals(a)) {
          previousIsD = true;
        } else {
          xs.add(a);
        }
      }
      javacArgs = xs;
      if (outDirName == null) {
        outDirPath = Files.createTempDirectory("topljavac-out");
      } else {
        FileSystem fs = FileSystems.getDefault();
        outDirPath = fs.getPath(outDirName);
        outDirPath = Files.createDirectories(outDirPath);
      }
    }

    File javacErr = File.createTempFile("topljavac", "stderr");
    Path inDirPath = Files.createTempDirectory("topljavac-in");

    { List<String> javacCommand = new ArrayList<>();
      javacCommand.add("javac");
      javacCommand.addAll(javacArgs);
      javacCommand.add("-d");
      javacCommand.add(outDirPath.toString());
      ProcessBuilder javacBuilder = new ProcessBuilder(javacCommand);
      // NOTE: Slight variations of the next line cause deadlocks. Careful.
      javacBuilder.redirectErrorStream(true).redirectOutput(javacErr);
      Process javac = javacBuilder.start();
      int result = javac.waitFor();
      if (result != 0) failedCommand(result, javacCommand);
      System.out.printf(
        "TOPL: javac finished successfully. Output in %s\n", outDirPath);
    }

    // === Step 2 ===
    { Files.delete(inDirPath);
      Files.move(outDirPath, inDirPath);
      List<String> toplcCommand = new ArrayList<>();
      toplcCommand.add("toplc");
      for (String j : toplJava) {
        toplcCommand.add("-e");
        toplcCommand.add(j);
      }
      toplcCommand.addAll(Arrays.asList(
        "-s", "-i", inDirPath.toString(), "-o", outDirPath.toString()));
      toplcCommand.addAll(toplProperties);
      ProcessBuilder toplcBuilder = new ProcessBuilder(toplcCommand);
      toplcBuilder.redirectOutput(ProcessBuilder.Redirect.INHERIT);
      toplcBuilder.redirectError(ProcessBuilder.Redirect.INHERIT);
      Process toplc = toplcBuilder.start();
      int result = toplc.waitFor();
      if (result != 0) failedCommand(result, toplcCommand);
      System.out.printf("TOPL: toplc finished successfully.\n");
    }


    // === Step 3 ===
    try (BufferedReader r = new BufferedReader(new FileReader("javac.err.topl"))) {
      // FIXME: brittle: util.ml and this file rely on a common constant
      // "java.err.topl"
      while (true) {
        String line = r.readLine();
        if (line == null) break;
        System.err.println(line);
      }
    }
    try (BufferedReader r = new BufferedReader(new FileReader(javacErr))) {
      while (true) {
        String line = r.readLine();
        if (line == null) break;
        System.err.println(line);
      }
    }
  }

  static List<String> expandArgFile(String... xs) throws IOException {
    List<String> ys = new ArrayList<>();
    for (String a : xs) {
      if (a.startsWith("@")) {
        // FIXME: Proper parsing? No proper docs, though: See what Javac does.
        // The following code handles what Infer produces now (Jun2017):
        try (BufferedReader br = new BufferedReader(new FileReader(a.substring(1))))
        { while (true) {
            String line = br.readLine();
            if (line == null) break;
            if (line.length() == 0) bail("empty line in argfile");
            if (line.startsWith("'")) line = line.substring(1, line.length() - 1);
            ys.add(line);
          }
        }
      } else {
        ys.add(a);
      }
    }
    return ys;
  }

  static void failedCommand(int result, List<String> command) {
    System.out.printf("failed (errorcode %d) to run:\n", result);
    for (String a : command) System.out.printf(" %s", a);
    System.out.printf("\n");
    bail("command returned nonzero error code");
  }

  static void bail(String message) {
    System.out.printf("E: %s\n", message);
    System.exit(0);
    // NOTE: If we return an error code, then Infer falls back to javac.
    // The user then has no idea that instrumentation failed.

    // FIXME: There should be some way to fail hard and stop Infer.
  }
}
