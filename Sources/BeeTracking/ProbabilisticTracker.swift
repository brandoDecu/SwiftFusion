import BeeDataset
import PenguinStructures
import SwiftFusion
import TensorFlow
import PythonKit
import Foundation


/// Runs the random projections tracker
/// Given a training set, it will train an RP tracker
/// and run it on one track in the test set:
///  - output: image with track and overlap metrics
public func runProbabilisticTracker<Encoder: AppearanceModelEncoder>(
  directory: URL,
  encoder: Encoder,
  onTrack trackIndex: Int,
  forFrames: Int = 80,
  withSampling samplingFlag: Bool = false,
  withFeatureSize d: Int = 100,
  savePatchesIn resultDirectory: String? = nil
) -> (fig: PythonObject, track: [Pose2], groundTruth: [Pose2]) {
  let trainingDatasetSize = 100
  let testSetStart = 100
  
  precondition(trainingDatasetSize <= testSetStart)

  // train foreground and background model and create tracker
  let trainingData = OISTBeeVideo(directory: directory, length: trainingDatasetSize)!
  let testData = OISTBeeVideo(directory: directory, afterIndex: testSetStart, length: forFrames)!

  precondition(testData.tracks[trackIndex].boxes.count == forFrames, "track length and required does not match")
  
  var tracker = trainProbabilisticTracker(
    trainingData: trainingData,
    encoder: encoder,
    frames: testData.frames,
    boundingBoxSize: (40, 70),
    withFeatureSize: d,
    fgRandomFrameCount: trainingDatasetSize,
    bgRandomFrameCount: trainingDatasetSize,
    numberOfTrainingSamples: 3000
  )
  
  // Run the tracker and return track with ground truth
  let (track, groundTruth) = createSingleTrack(
    onTrack: trackIndex, withTracker: &tracker,
    andTestData: testData, withSampling: samplingFlag
  )
  
  // Now create trajectory and metrics plot
  let plt = Python.import("matplotlib.pyplot")
  let (fig, axes) = plt.subplots(2, 1, figsize: Python.tuple([6, 12])).tuple2
  plotTrajectory(
    track: track, withGroundTruth: groundTruth, on: axes[0],
    withTrackColors: plt.cm.jet, withGtColors: plt.cm.gray
  )
  
  plotOverlap(
    track: track, withGroundTruth: groundTruth, on: axes[1]
  )

  if let dir = resultDirectory {
    /// Plot all the frames so we can visually inspect the situation
    for i in track.indices {
      let (fig_initial, _) = plotPatchWithGT(frame: testData.frames[i], actual: track[i], expected: groundTruth[i])
      fig_initial.savefig("\(dir)/track\(trackIndex)_\(d)_\(i).png", bbox_inches: "tight")
      plt.close(fig: fig_initial)
    }
  }

  return (fig, track, groundTruth)
}

// Simple two-component mixture model in 2D
struct TwoComponents : McEmModel {
  typealias Datum = Tensor<Double>
  enum Hidden { case one; case two}
  typealias HyperParameters = MultivariateGaussian.HyperParameters
  
  public var c1, c2 : MultivariateGaussian
  
  /// Initialize to uninitialized components
  init(from data:[Datum],
       using sourceOfEntropy: inout AnyRandomNumberGenerator,
       given p: HyperParameters?) {
    c1 = MultivariateGaussian(mean:data[0], information: eye(rowCount: 10))
    c2 = MultivariateGaussian(mean:data[1], information: eye(rowCount: 10))
  }
  
  /// Given a datum and a model, sample from the hidden variables
  func sample(count:Int, for datum: Datum,
              using sourceOfEntropy: inout AnyRandomNumberGenerator) -> [Hidden] {
    let E1 = c1.negativeLogLikelihood(datum)
    let E2 = c2.negativeLogLikelihood(datum)

    let p1_over_p2 = (c1.constant / c2.constant) * exp(E2 - E1)
    let labels : [Hidden] = (0..<count).map { _ in
      let u = Double.random(in: 0..<(p1_over_p2 + 1), using: &sourceOfEntropy)
      return u<=p1_over_p2 ? .one : .two
    }
    return labels
  }
  
  /// Given an array of labeled datums, fit the two Gaussian mixture components
  init(from labeledData: [LabeledDatum], given p: HyperParameters?=nil) {
    let data1 = labeledData.filter { $0.0 == .one}
    let data2 = labeledData.filter { $0.0 == .two}
    self.c1 = MultivariateGaussian(from: Tensor<Double>(data1.map { $0.1 }), given:p)
    self.c2 = MultivariateGaussian(from: Tensor<Double>(data2.map { $0.1 }), given:p)
  }
}

/// Train a random projection tracker with a full Gaussian foreground model
/// and a Naive Bayes background model.
public func trainProbabilisticTracker<
  Encoder: AppearanceModelEncoder,
  ForegroundModel: GenerativeDensity,
  BackgroundModel: GenerativeDensity
>(
  trainingData: OISTBeeVideo,
  encoder: Encoder,
  frames: [Tensor<Float>],
  boundingBoxSize: (Int, Int), withFeatureSize d: Int,
  fgRandomFrameCount: Int = 10,
  bgRandomFrameCount: Int = 10,
  numberOfTrainingSamples: Int = 3000,
  foregroundModel: (_ batchPositive: Tensor<Double>) -> ForegroundModel,
  backgroundModel: (_ batchNegative: Tensor<Double>) -> BackgroundModel
) -> TrackingConfiguration<Tuple1<Pose2>> {
  let (fg, bg, statistics) = getTrainingBatches(
    dataset: trainingData, boundingBoxSize: boundingBoxSize,
    fgBatchSize: numberOfTrainingSamples,
    bgBatchSize: numberOfTrainingSamples,
    fgRandomFrameCount: fgRandomFrameCount,
    bgRandomFrameCount: bgRandomFrameCount,
    useCache: true
  )

  let batchPositive = encoder.encode(fg)
  let batchNegative = encoder.encode(bg)

  // let foregroundModel = MultivariateGaussian(from:batchPositive, regularizer: 1e-3)
  let generator = ARC4RandomNumberGenerator(seed: 11)
  var em = MonteCarloEM<TwoComponents>(sourceOfEntropy: generator)
  let twoComp = em.run(with: Tensor(concatenating: [batchPositive, batchNegative], alongAxis: 0).unstacked(alongAxis: 0), iterationCount: 10)
  let foregroundModel = twoComp.c1
  let backgroundModel = twoComp.c2

  // let backgroundModel = MultivariateGaussian(from: batchNegative, regularizer: 1e-3)

  let tracker = makeProbabilisticTracker(
    model: encoder, statistics: statistics,
    frames: frames, targetSize: boundingBoxSize,
    foregroundModel: foregroundModel, backgroundModel: backgroundModel
  )

  return tracker
}


/// Returns a tracking configuration for a tracker using an random projection.
///
/// Parameter model: The random projection model to use.
/// Parameter statistics: Normalization statistics for the frames.
/// Parameter frames: The frames of the video where we want to run tracking.
/// Parameter targetSize: The size of the target in the frames.
public func makeProbabilisticTracker<Encoder: AppearanceModelEncoder, ForegroundModel: GenerativeDensity, BackgroundModel: GenerativeDensity>(
  model: Encoder,
  statistics: FrameStatistics,
  frames: [Tensor<Float>],
  targetSize: (Int, Int),
  foregroundModel: ForegroundModel,
  backgroundModel: BackgroundModel
) -> TrackingConfiguration<Tuple1<Pose2>> {
  var variableTemplate = VariableAssignments()
  var frameVariableIDs = [Tuple1<TypedID<Pose2>>]()
  for _ in 0..<frames.count {
    frameVariableIDs.append(
      Tuple1(
        variableTemplate.store(Pose2())
        ))
  }

  let addPrior = { (variables: Tuple1<TypedID<Pose2>>, values: Tuple1<Pose2>, graph: inout FactorGraph) -> () in
    let (poseID) = unpack(variables)
    let (pose) = unpack(values)
    graph.store(WeightedPriorFactorPose2(poseID, pose, weight: 1e-2, rotWeight: 2e2))
  }

  let addTrackingFactor = { (variables: Tuple1<TypedID<Pose2>>, frame: Tensor<Float>, graph: inout FactorGraph) -> () in
    let (poseID) = unpack(variables)
    graph.store(
      ProbablisticTrackingFactor(poseID,
        measurement: statistics.normalized(frame),
        encoder: model,
        patchSize: targetSize,
        appearanceModelSize: targetSize,
        foregroundModel: foregroundModel,
        backgroundModel: backgroundModel,
        maxPossibleNegativity: 1e4
      )
    )
  }

  return TrackingConfiguration(
    frames: frames,
    variableTemplate: variableTemplate,
    frameVariableIDs: frameVariableIDs,
    addPriorFactor: addPrior,
    addTrackingFactor: addTrackingFactor,
    addBetweenFactor: { (variables1, variables2, graph) -> () in
      let (poseID1) = unpack(variables1)
      let (poseID2) = unpack(variables2)
      graph.store(WeightedBetweenFactorPose2(poseID1, poseID2, Pose2(), weight: 1e-2, rotWeight: 2e2))
    },
    addFixedBetweenFactor: { (values, variables, graph) -> () in
      let (prior) = unpack(values)
      let (poseID) = unpack(variables)
      graph.store(WeightedPriorFactorPose2SD(poseID, prior, sdX: 8, sdY: 4.6, sdTheta: 0.3))
    })
}

/// Returns `t` as a Swift tuple.
fileprivate func unpack<A, B>(_ t: Tuple2<A, B>) -> (A, B) {
  return (t.head, t.tail.head)
}
/// Returns `t` as a Swift tuple.
fileprivate func unpack<A>(_ t: Tuple1<A>) -> (A) {
  return (t.head)
}
