import Foundation
import XCTest
@testable import KsApi
@testable import ReactiveExtensions
@testable import ReactiveExtensions_TestHelpers
import KsApi
import ReactiveCocoa
import Result
@testable import Library
import Prelude

// swiftlint:disable function_body_length
internal final class SearchViewModelTests: TestCase {
  private let vm: SearchViewModelType! = SearchViewModel()

  private let changeSearchFieldFocusFocused = TestObserver<Bool, NoError>()
  private let changeSearchFieldFocusAnimated = TestObserver<Bool, NoError>()
  private let isPopularTitleVisible = TestObserver<Bool, NoError>()
  private let hasProjects = TestObserver<Bool, NoError>()
  private let searchFieldText = TestObserver<String, NoError>()

  override func setUp() {
    super.setUp()

    self.vm.outputs.changeSearchFieldFocus.map(first).observe(self.changeSearchFieldFocusFocused.observer)
    self.vm.outputs.changeSearchFieldFocus.map(second).observe(self.changeSearchFieldFocusAnimated.observer)
    self.vm.outputs.isPopularTitleVisible.observe(self.isPopularTitleVisible.observer)
    self.vm.outputs.projects.map { !$0.isEmpty }.observe(self.hasProjects.observer)
    self.vm.outputs.searchFieldText.observe(self.searchFieldText.observer)
  }

  func testChangeSearchFieldFocus() {
    self.vm.inputs.viewDidAppear()

    self.changeSearchFieldFocusFocused.assertValues([false])
    self.changeSearchFieldFocusAnimated.assertValues([false])

    self.vm.inputs.searchFieldDidBeginEditing()

    self.changeSearchFieldFocusFocused.assertValues([false, true])
    self.changeSearchFieldFocusAnimated.assertValues([false, true])

    self.vm.inputs.cancelButtonPressed()

    self.changeSearchFieldFocusFocused.assertValues([false, true, false])
    self.changeSearchFieldFocusAnimated.assertValues([false, true, true])
  }

  // Tests a standard flow of searching for projects.
  func testFlow() {
    self.hasProjects.assertDidNotEmitValue("No projects before view is visible.")
    self.isPopularTitleVisible.assertDidNotEmitValue("Popular title is not visible before view is visible.")
    XCTAssertEqual([], trackingClient.events, "No events tracked before view is visible.")

    self.vm.inputs.viewDidAppear()
    self.scheduler.advance()

    self.hasProjects.assertValues([true], "Projects emitted immediately upon view appearing.")
    self.isPopularTitleVisible.assertValues([true], "Popular title visible upon view appearing.")
    XCTAssertEqual(["Discover Search"], trackingClient.events,
                   "The search view event tracked upon view appearing.")

    self.vm.inputs.searchTextChanged("skull graphic tee")

    self.hasProjects.assertValues([true, false], "Projects clear immediately upon entering search.")
    self.isPopularTitleVisible.assertValues([true, false],
                                       "Popular title hide immediately upon entering search.")

    self.scheduler.advance()

    self.hasProjects.assertValues([true, false, true], "Projects emit after waiting enough time.")
    self.isPopularTitleVisible.assertValues([true, false],
                                       "Popular title visibility still not emit after time has passed.")
    XCTAssertEqual(["Discover Search", "Discover Search Results"], trackingClient.events,
                   "A koala event is tracked for the search results.")
    XCTAssertEqual("skull graphic tee", trackingClient.properties.last!["search_term"] as? String)

    self.vm.inputs.searchTextChanged("")
    self.scheduler.advance()

    self.hasProjects.assertValues([true, false, true, false, true],
                             "Clearing search clears projects and brings back popular projects.")
    self.isPopularTitleVisible.assertValues([true, false, true],
                                       "Clearing search brings back popular title.")
    XCTAssertEqual(["Discover Search", "Discover Search Results"], trackingClient.events)

    self.vm.inputs.viewDidAppear()

    self.hasProjects.assertValues([true, false, true, false, true],
                             "Leaving view and coming back doesn't load more projects.")
    self.isPopularTitleVisible.assertValues([true, false, true],
                                       "Leaving view and coming back doesn't change popular title")
    XCTAssertEqual(["Discover Search", "Discover Search Results"], trackingClient.events,
                   "Leaving view and coming back doesn't emit more koala events.")
  }

  // Confirms that clearing search during an in-flight search doesn't cause search results and popular
  // projects to get mixed up.
  func testOrderingOfPopularAndDelayedSearches() {
    withEnvironment(debounceInterval: TestCase.interval) {
      let projects = TestObserver<[Int], NoError>()
      self.vm.outputs.projects.map { $0.map { $0.id } }.observe(projects.observer)

      self.vm.inputs.viewDidAppear()
      self.scheduler.advance()

      self.hasProjects.assertValues([true], "Popular projects emit immediately.")
      let popularProjects = projects.values.last!

      self.vm.inputs.searchTextChanged("skull graphic tee")

      self.hasProjects.assertValues([true, false], "Clears projects immediately.")

      self.scheduler.advanceByInterval(TestCase.interval / 2.0)

      self.hasProjects.assertValues([true, false], "Doesn't emit projects after a little time.")

      self.vm.inputs.searchTextChanged("")
      self.scheduler.advance()

      self.hasProjects.assertValues([true, false, true], "Brings back popular projets immediately.")
      projects.assertLastValue(popularProjects, "Brings back popular projects immediately.")

      self.scheduler.run()

      self.hasProjects.assertValues([true, false, true],
                               "Doesn't search for projects after time enough time passes.")
      projects.assertLastValue(popularProjects, "Brings back popular projects immediately.")

      XCTAssertEqual(["Discover Search"], trackingClient.events)
    }
  }

  // Confirms that entering new search terms cancels previously in-flight API requests for projects,
  // and that ultimately only one set of projects is returned.
  func testCancelingOfSearchResultsWhenEnteringNewSearchTerms() {
    let apiDelay = 2.0
    let debounceDelay = 1.0

    withEnvironment(apiDelayInterval: apiDelay, debounceInterval: debounceDelay) {
      let projects = TestObserver<[Int], NoError>()
      self.vm.outputs.projects.map { $0.map { $0.id } }.observe(projects.observer)

      self.vm.inputs.viewDidAppear()
      self.scheduler.advanceByInterval(apiDelay)

      self.hasProjects.assertValues([true], "Popular projects load immediately.")

      self.vm.inputs.searchTextChanged("skull")

      self.hasProjects.assertValues([true, false], "Projects clear after entering search term.")

      // wait a little bit of time, but not enough to complete the debounce
      self.scheduler.advanceByInterval(debounceDelay / 2.0)

      self.hasProjects.assertValues([true, false],
                               "No new projects load after waiting enough a little bit of time.")

      self.vm.inputs.searchTextChanged("skull graphic")

      self.hasProjects.assertValues([true, false], "No new projects load after entering new search term.")

      // wait a little bit of time, but not enough to complete the debounce
      self.scheduler.advanceByInterval(debounceDelay / 2.0)

      self.hasProjects.assertValues([true, false], "No new projects load after entering new search term.")

      // Wait enough time for debounced request to be made, but not enough time for it to finish.
      self.scheduler.advanceByInterval(debounceDelay / 2.0)

      self.hasProjects.assertValues([true, false],
                               "No projects emit after waiting enough time for API to request to be made")

      self.vm.inputs.searchTextChanged("skull graphic tee")

      self.hasProjects.assertValues([true, false],
                                    "Still no new projects after entering another search term.")

      // wait enough time for API request to be fired.
      self.scheduler.advanceByInterval(debounceDelay + apiDelay)

      self.hasProjects.assertValues([true, false, true], "Search projects load after waiting enough time.")
      XCTAssertEqual(["Discover Search", "Discover Search Results"], trackingClient.events)

      // run out the scheduler
      self.scheduler.run()

      self.hasProjects.assertValues([true, false, true], "Nothing new is emitted.")
      XCTAssertEqual(["Discover Search", "Discover Search Results"],
                     self.trackingClient.events,
                     "Nothing new is tracked.")
    }
  }

  func testSearchFieldText() {
    self.vm.inputs.viewDidAppear()
    self.vm.inputs.searchFieldDidBeginEditing()

    self.searchFieldText.assertValues([])

    self.vm.inputs.searchTextChanged("HELLO")

    self.searchFieldText.assertValues([])

    self.vm.inputs.cancelButtonPressed()

    self.searchFieldText.assertValues([""])
  }
}
