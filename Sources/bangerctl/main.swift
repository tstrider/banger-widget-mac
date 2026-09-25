//  main.swift — bangerctl entry point.

import Foundation

exit(BangerCTL.run(Array(CommandLine.arguments.dropFirst())))
