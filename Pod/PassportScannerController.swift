//
//  PassportScannerController.swift
//
//  Created by Edwin Vermeer on 9/7/15.
//  Copyright (c) 2015. All rights reserved.
//

import Foundation
import UIKit
import TesseractOCR
import GPUImage
import UIImage_Resize

public class PassportScannerController: UIViewController, G8TesseractDelegate {

    /// Set debug to true if you want to see what's happening
    public var debug = false
    /// Set accuracy that is required for the scan. 1 = all checksums should be ok
    public var accuracy: Float = 6
    /// When you create your own view, then make sure you have a GPUImageView that is linked to this
    @IBOutlet var filterView: GPUImageView!

    ///  wait a fraction of a second between scans to give the system time to handle things.
    var timer: Timer? //

    /// For capturing the video and passing it on to the filters.
    private let videoCamera: GPUImageVideoCamera

    // Quick reference to the used filter configurations
    var exposure = GPUImageExposureFilter()
    var highlightShadow = GPUImageHighlightShadowFilter()
    var saturation = GPUImageSaturationFilter()
    var contrast = GPUImageContrastFilter()
    var adaptiveTreshold = GPUImageAdaptiveThresholdFilter()
    var crop = GPUImageCropFilter()
    var averageColor = GPUImageAverageColor()
    var blendFilter = GPUImageAddBlendFilter()

    /// The tesseract OCX engine
    var tesseract: G8Tesseract = G8Tesseract(language: "eng")

    /**
    Initializer that will initialize the video camera forced to portait mode

    :param: aDecoder the NSCOder

    :returns: instance of this controller
    */
    public required init?(coder aDecoder: NSCoder) {
        videoCamera = GPUImageVideoCamera(sessionPreset: AVCaptureSessionPreset1920x1080, cameraPosition: .back)
        videoCamera.outputImageOrientation = .portrait
        super.init(coder: aDecoder)
    }

    /**
     Make sure we only have the app in .Portrait
     
     :returns: .Portrait orientation
     */
    override public var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        get {
            return .portrait
        }
    }
    
    /**
     Hide the status bar
     
     :returns: true will hide the status bar
     */
    override public var prefersStatusBarHidden: Bool {
        get {
            return true
        }
    }

    /**
    Initialize all graphic filters in the viewDidLoad
    */
    public override func viewDidLoad() {
        super.viewDidLoad()

        // Filter settings
        exposure.exposure = 0.8 // -10 - 10
        highlightShadow.highlights  = 0.7 // 0 - 1
        saturation.saturation  = 0.3 // 0 - 2
        contrast.contrast = 4.0  // 0 - 4
        adaptiveTreshold.blurRadiusInPixels = 8.0

        

        // Only use this area for the OCR
        crop.cropRegion = CGRect(x: 500.0/1080.0, y: 110.0/1920.0, width: 500.0/1080, height: 1920.0/1920.0)
        
        // Try to dinamically optimize the exposure based on the average color
        averageColor.colorAverageProcessingFinishedBlock = {(redComponent, greenComponent, blueComponent, alphaComponent, frameTime) in
            let lighting = redComponent + greenComponent + blueComponent
            let currentExposure = self.exposure.exposure
            // The stablil color is between 2.85 and 2.91. Otherwise change the exposure
            if lighting < 2.85 {
                self.exposure.exposure = currentExposure + (2.88 - lighting) * 2
            }
            if lighting > 2.91 {
                self.exposure.exposure = currentExposure - (lighting - 2.88) * 2
            }
            if self.exposure.exposure > 3 {
                self.exposure.exposure = 3
            }
            if self.exposure.exposure < 0.5 {
                self.exposure.exposure = 0.5
            }
        }

        // Chaining the filters
        videoCamera.addTarget(exposure)
        exposure.addTarget(highlightShadow)
        highlightShadow.addTarget(saturation)
        saturation.addTarget(contrast)
        contrast.addTarget(self.filterView)

        // Strange! Adding this filter will give a great readable picture, but the OCR won't work.
        //contrast.addTarget(adaptiveTreshold)
        //adaptiveTreshold.addTarget(self.filterView)

        // Adding these 2 extra filters to automatically control exposure depending of the average color in the scan area
        contrast.addTarget(crop)
        crop.addTarget(averageColor)
        

        self.view.backgroundColor = UIColor.gray
    }

    public func preprocessedImage(for tesseract: G8Tesseract!, sourceImage: UIImage!) -> UIImage! {
        // sourceImage is the same image you sent to Tesseract above.
        // Processing is already done in dynamic filters
        return sourceImage
    }
    
    /**
    call this from your code to start a scan immediately or hook it to a button.

    :param: sender The sender of this event
    */
    @IBAction public func StartScan(sender: AnyObject) {
        self.view.backgroundColor = UIColor.black

        self.videoCamera.startCapture()
        self.timer = Timer.scheduledTimer(timeInterval: 0.01, target: self, selector: #selector(PassportScannerController.scan), userInfo: nil, repeats: false)
    }

    /**
    call this from your code to stop a scan or hook it to a button

    :param: sender the sender of this event
    */
    @IBAction public func StopScan(sender: AnyObject) {
        self.view.backgroundColor = UIColor.white
        self.videoCamera.stopCapture()
        timer?.invalidate()
        timer = nil
        abbortScan()
    }

    /**
    Perform a scan
    */
    public func scan() {
        self.timer?.invalidate()
        self.timer = nil
        print("Start OCR")
        // Get a snapshot from this filter, should be from the next runloop
        let currentFilterConfiguration = contrast
        OperationQueue.main.addOperation {
            currentFilterConfiguration.useNextFrameForImageCapture()
            let snapshot = currentFilterConfiguration.imageFromCurrentFramebuffer()
            if snapshot == nil {
                print("- Could not get snapshot from camera")
                self.StartScan(sender: self)
                return
            }
            print("- Could get snapshot from camera")
            var result: String?
            autoreleasepool {
                // Crop scan area
                let cropRect: CGRect! = CGRect(x: 500.0, y: 110, width: 500.0, height: 1920.0)
                let imageRef: CGImage! = snapshot!.cgImage!.cropping(to: cropRect)
                //let croppedImage:UIImage = UIImage(CGImage: imageRef)
                // Four times faster scan speed when the image is smaller. Another bennefit is that the OCR results are better at this resolution
                let croppedImage: UIImage =   UIImage(cgImage: imageRef).resizedImageToFit(in: CGSize(width: 500 * 1.0, height: 1920.0 * 1.0 ), scaleIfSmaller: true)
                // Rotate cropped image
                let selectedFilter = GPUImageTransformFilter()
                selectedFilter.setInputRotation(kGPUImageRotateLeft, at: 0)
                let image: UIImage = selectedFilter.image(byFilteringImage: croppedImage) // Need to do something for filter image error
                let heightInPoints = image.size.height
                let heightInPixels = heightInPoints * image.scale
                let widthInPoints = image.size.width
                let widthInPixels = widthInPoints * image.scale
                print(heightInPixels, widthInPixels)
                
                //To check Image Dpi
            
//                var imagePropertiesDict = CGImageSourceCopyPropertiesAtIndex(image, 0, nil)
              

                // Start OCR
                // download traineddata to tessdata folder for language from:
                // https://code.google.com/p/tesseract-ocr/downloads/list
                // ocr traineddata ripped from:
                // http://getandroidapp.org/applications/business/79952-nfc-passport-reader-2-0-8.html
                // see http://www.sk-spell.sk.cx/tesseract-ocr-en-variables
                self.tesseract.setVariableValue("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ<", forKey: "tessedit_char_whitelist")
                self.tesseract.setVariableValue("FALSE", forKey: "x_ht_quality_check")
                self.tesseract.delegate = self
                
//Testing OCR optimisations
                self.tesseract.image = image
                print("- Start recognize")
                self.tesseract.recognize()
                result = self.tesseract.recognizedText
                //tesseract = nil
                G8Tesseract.clearCache()
            }

            print("Scanresult : \(result)")

            // Perform OCR
            if let r = result {
                let mrz = MRZ(scan: r, debug: self.debug)
                if  mrz.isValid <= self.accuracy {
                    print("Scan quality insufficient : \(mrz.isValid)")
                } else {
                    print("Scan quality insufficient : \(mrz.isValid)")
                    self.videoCamera.stopCapture()
                    self.succesfullScan(mrz: mrz)
                    return
                }
            }
            self.StartScan(sender: self)

        }
    }

    /**
    Override this function in your own class for processing the result

    :param: mrz The MRZ result
    */
    public func succesfullScan(mrz: MRZ) {
        print("Scan results was successfull")
        let alert = UIAlertView(title: "Scan Results Are",
                                message: "Make sure your device is connected to the Internet.",
                                delegate: nil,
                                cancelButtonTitle: "OK")
        alert.show()
        _ =  self.navigationController?.popToRootViewController(animated: true)
        assertionFailure("You should overwrite this function to handle the scan results")
    }

   
    public func abbortScan() {
        assertionFailure("You should overwrite this function to handle the scan results")
    }


}
