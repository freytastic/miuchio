import 'package:integration_test/integration_test.dart';
import 'package:miuchio/secure_store/secure_key_store.dart';

// The host contract suite, run against the real platform store
import '../../test/secure_store/contract_test.dart' as contract;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  contract.runContractTests(
      'Real platform store', () => createSecureKeyStore());
}
