import java.util.Map;

public class CriarVariaveisEAbrirConsole {

    public static void main(String[] args) throws Exception {
        ProcessBuilder builder = new ProcessBuilder(
            "cmd.exe", "/c", "start", "\"UmBenchmark\"", "cmd.exe", "/k"
        );

        Map<String, String> ambiente = builder.environment();
        ambiente.put("UmPe", "Saci");
        ambiente.put("PePraTras", "Caipora");

        builder.start();
    }
}
