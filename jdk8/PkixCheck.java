import java.io.FileInputStream;
import java.io.InputStream;
import java.net.URL;
import java.security.KeyStore;
import java.security.cert.CertPath;
import java.security.cert.CertPathValidator;
import java.security.cert.CertPathValidatorException;
import java.security.cert.CertificateFactory;
import java.security.cert.PKIXParameters;
import java.security.cert.TrustAnchor;
import java.security.cert.X509Certificate;
import java.util.ArrayList;
import java.util.Collection;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManagerFactory;
import javax.security.auth.x500.X500Principal;

// Validate one direct chain with JDK 8 PKIX. The intermediate file may also
// contain a cross-certificate; only the path that ends at ROOT is checked.
// A hostname, when given, is probed afterwards and does not change the result.
public class PkixCheck {
    public static void main(String[] args) throws Exception {
        if (args.length != 5 && args.length != 6) {
            System.err.println("usage: PkixCheck TRUSTSTORE PASSWORD LEAF UNTRUSTED ROOT [HOST]");
            System.exit(2);
        }
        String storePath = args[0];
        char[] password = args[1].toCharArray();
        X509Certificate leaf = readOne(args[2]);
        List<X509Certificate> pool = readAll(args[3]);
        X509Certificate root = readOne(args[4]);
        String host = args.length == 6 ? args[5] : "";

        List<X509Certificate> path = new ArrayList<X509Certificate>();
        path.add(leaf);
        if (!leaf.getIssuerX500Principal().equals(root.getSubjectX500Principal())) {
            if (!extend(leaf.getIssuerX500Principal(), root, pool, path, 0)) {
                System.err.println("no direct path to " + root.getSubjectX500Principal().getName());
                System.exit(2);
            }
        }
        for (int i = 1; i < path.size(); i++) {
            System.out.println("intermediate: " + path.get(i).getSubjectX500Principal().getName());
        }

        KeyStore store = KeyStore.getInstance("JKS");
        InputStream in = new FileInputStream(storePath);
        try {
            store.load(in, password);
        } finally {
            in.close();
        }
        Set<TrustAnchor> anchors = new HashSet<TrustAnchor>();
        java.util.Enumeration<String> aliases = store.aliases();
        while (aliases.hasMoreElements()) {
            String alias = aliases.nextElement();
            if (store.isCertificateEntry(alias)) {
                anchors.add(new TrustAnchor((X509Certificate) store.getCertificate(alias), null));
            }
        }
        if (anchors.isEmpty()) {
            System.err.println("no trustedCertEntry in " + storePath);
            System.exit(2);
        }

        CertificateFactory factory = CertificateFactory.getInstance("X.509");
        CertPath certPath = factory.generateCertPath(path);
        PKIXParameters params = new PKIXParameters(anchors);
        params.setRevocationEnabled(false);
        int exit = 0;
        try {
            CertPathValidator.getInstance("PKIX").validate(certPath, params);
            System.out.println("trusted");
        } catch (CertPathValidatorException e) {
            System.out.println("not trusted: " + e.getMessage());
            exit = 1;
        }

        if (!host.isEmpty()) {
            probe(store, host);
        }
        System.exit(exit);
    }

    private static boolean extend(X500Principal want, X509Certificate root,
                                  List<X509Certificate> pool, List<X509Certificate> path, int depth) {
        if (want.equals(root.getSubjectX500Principal())) {
            return true;
        }
        if (depth > 6) {
            return false;
        }
        for (X509Certificate cert : pool) {
            if (cert.getSubjectX500Principal().equals(cert.getIssuerX500Principal())) {
                continue;
            }
            if (!cert.getSubjectX500Principal().equals(want)) {
                continue;
            }
            path.add(cert);
            if (extend(cert.getIssuerX500Principal(), root, pool, path, depth + 1)) {
                return true;
            }
            path.remove(path.size() - 1);
        }
        return false;
    }

    private static X509Certificate readOne(String path) throws Exception {
        List<X509Certificate> all = readAll(path);
        if (all.size() != 1) {
            throw new IllegalArgumentException(path + " has " + all.size() + " certificates");
        }
        return all.get(0);
    }

    private static List<X509Certificate> readAll(String path) throws Exception {
        CertificateFactory factory = CertificateFactory.getInstance("X.509");
        InputStream in = new FileInputStream(path);
        try {
            Collection<?> parsed = factory.generateCertificates(in);
            List<X509Certificate> certs = new ArrayList<X509Certificate>();
            for (Object item : parsed) {
                certs.add((X509Certificate) item);
            }
            return certs;
        } finally {
            in.close();
        }
    }

    private static void probe(KeyStore store, String host) {
        try {
            TrustManagerFactory trust = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
            trust.init(store);
            SSLContext context = SSLContext.getInstance("TLS");
            context.init(null, trust.getTrustManagers(), null);
            URL url = new URL("https://" + host + "/");
            HttpsURLConnection connection = (HttpsURLConnection) url.openConnection();
            connection.setSSLSocketFactory(context.getSocketFactory());
            connection.setConnectTimeout(20000);
            connection.setReadTimeout(20000);
            connection.connect();
            System.out.println("handshake: " + connection.getResponseCode());
            connection.disconnect();
        } catch (Exception e) {
            System.out.println("handshake: " + e.getClass().getSimpleName() + ": " + e.getMessage());
        }
    }
}
