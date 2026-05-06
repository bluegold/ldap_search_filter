#include "ldap_filter.hpp"

int main(int argc, char **argv) {
  std::vector<std::string> args;
  for (int i = 1; i < argc; ++i) {
    args.emplace_back(argv[i]);
  }
  return ldf::runCli(args);
}
